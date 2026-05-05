-- lazyagent/mcp/tools.lua
-- MCP tool implementations exposed to agents via the MCP server.
-- Each tool has: description, inputSchema, and a handler(params) -> result | error

local M = {}
local state = require("lazyagent.logic.state")
local backend_logic = require("lazyagent.logic.backend")
local agent_logic = require("lazyagent.logic.agent")
local diff_utils = require("lazyagent.acp.diff")
local uv = vim.uv or vim.loop

local function normalize_fs_path(path)
  path = tostring(path or "")
  if path == "" then
    return nil
  end
  local normalized = vim.fn.fnamemodify(path, ":p")
  if vim.fs and type(vim.fs.normalize) == "function" then
    normalized = vim.fs.normalize(normalized)
  end
  return normalized
end

local function file_stat_stamp(path)
  path = normalize_fs_path(path)
  if not path then
    return { exists = false, size = -1, sec = -1, nsec = -1 }
  end

  if uv and type(uv.fs_stat) == "function" then
    local stat = uv.fs_stat(path)
    if stat then
      local mtime = stat.mtime or {}
      return {
        exists = true,
        size = tonumber(stat.size or -1) or -1,
        sec = tonumber(mtime.sec or mtime.tv_sec or -1) or -1,
        nsec = tonumber(mtime.nsec or mtime.tv_nsec or 0) or 0,
      }
    end
  end

  local sec = tonumber(vim.fn.getftime(path)) or -1
  if sec < 0 then
    return { exists = false, size = -1, sec = -1, nsec = -1 }
  end

  return {
    exists = true,
    size = tonumber(vim.fn.getfsize(path)) or -1,
    sec = sec,
    nsec = 0,
  }
end

local function same_file_stat(a, b)
  a = a or {}
  b = b or {}
  return a.exists == b.exists
    and tonumber(a.size or -1) == tonumber(b.size or -1)
    and tonumber(a.sec or -1) == tonumber(b.sec or -1)
    and tonumber(a.nsec or -1) == tonumber(b.nsec or -1)
end

local function changed_file_snapshot(cwd)
  local snapshot = {}
  local all = vim.fn.systemlist(
    "git -C " .. vim.fn.shellescape(cwd) .. " status --short 2>/dev/null | awk '{print $NF}'"
  )
  if not all or #all == 0 then
    return snapshot
  end

  for _, rel in ipairs(all) do
    local abs = normalize_fs_path(cwd .. "/" .. rel)
    if abs then
      snapshot[abs] = {
        rel = rel,
        stat = file_stat_stamp(abs),
      }
    end
  end
  return snapshot
end

-- Return git-changed files touched during the current turn.
-- Falls back to mtime filtering if no per-turn snapshot exists.
local function changed_files_since(cwd, since)
  local all = vim.fn.systemlist(
    "git -C " .. vim.fn.shellescape(cwd) .. " status --short 2>/dev/null | awk '{print $NF}'"
  )
  if not all or #all == 0 then return {} end
  local normalized_cwd = normalize_fs_path(cwd)
  local snapshot = normalized_cwd and state._hook_turn_cwd == normalized_cwd and state._hook_turn_snapshot or nil
  if type(snapshot) == "table" then
    local result = {}
    for _, rel in ipairs(all) do
      local abs = normalize_fs_path(cwd .. "/" .. rel)
      local before = abs and snapshot[abs] or nil
      local after = abs and file_stat_stamp(abs) or nil
      if not before or not same_file_stat(before.stat, after) then
        table.insert(result, rel)
      end
    end
    return result
  end
  if not since then return all end
  local result = {}
  for _, rel in ipairs(all) do
    local abs = cwd .. "/" .. rel
    if vim.fn.getftime(abs) >= since then
      table.insert(result, rel)
    end
  end
  return result
end

local function begin_edit_tracking(cwd)
  cwd = normalize_fs_path(cwd or vim.fn.getcwd())
  state._hook_turn_start = os.time()
  state._hook_turn_cwd = cwd
  state._hook_turn_snapshot = cwd and changed_file_snapshot(cwd) or {}
  local hopts = (state.opts and state.opts.hooks) or {}
  if hopts.quickfix_on_edit ~= false then
    state._qf_items = {}
    vim.fn.setqflist({}, "r", { title = "Agent turn", items = {} })
  end
  -- Stop any active diagnostic-review loop and clear fix-request flag when a new agent turn begins
  state._diagnostic_loop_active = false
  state._fix_requested = false
end

local function resolve_tool_cwd(params)
  params = type(params) == "table" and params or {}
  if params.cwd and params.cwd ~= "" then
    return normalize_fs_path(params.cwd)
  end
  local session = params.agent_name and state.sessions and state.sessions[params.agent_name] or nil
  local cwd = session and (session.root_dir or session.cwd) or vim.fn.getcwd()
  return normalize_fs_path(cwd)
end

local function resolve_target_path(path, cwd)
  path = tostring(path or "")
  if path == "" then
    return nil
  end
  if path:sub(1, 1) == "/" then
    return normalize_fs_path(path)
  end
  return normalize_fs_path((cwd or vim.fn.getcwd()) .. "/" .. path)
end

local function reload_loaded_buffers_for_paths(cwd, files)
  if type(files) ~= "table" or #files == 0 then
    return { reloaded = 0, skipped_modified = 0 }
  end

  local targets = {}
  for _, rel in ipairs(files) do
    local abs = resolve_target_path(rel, cwd)
    if abs and vim.fn.filereadable(abs) == 1 then
      targets[abs] = true
    end
  end
  if not next(targets) then
    return { reloaded = 0, skipped_modified = 0 }
  end

  local result = { reloaded = 0, skipped_modified = 0 }
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
      local name = normalize_fs_path(vim.api.nvim_buf_get_name(bufnr))
      if name and targets[name] and vim.bo[bufnr].buftype == "" then
        if vim.bo[bufnr].modified then
          result.skipped_modified = result.skipped_modified + 1
        else
          pcall(vim.cmd, "silent checktime " .. tostring(bufnr))
          result.reloaded = result.reloaded + 1
        end
      end
    end
  end

  return result
end

local function hook_reload_enabled()
  return ((((state.opts or {}).hooks or {}).reload_mode) or "hook") ~= "watch"
end

local function git_diff_for_path(cwd, abs_path)
  local diff = vim.fn.systemlist(
    "git -C " .. vim.fn.shellescape(cwd)
    .. " diff --unified=0 -- " .. vim.fn.shellescape(abs_path)
    .. " 2>/dev/null"
  )
  if vim.v.shell_error ~= 0 or type(diff) ~= "table" then
    return {}
  end
  return diff
end

local function changed_line_from_diff(cwd, abs_path, params)
  local diff = git_diff_for_path(cwd, abs_path)
  if not diff or #diff == 0 then
    return 1
  end

  local line = diff_utils.line_for_change(
    params.oldText or params.old_text,
    params.newText or params.new_text,
    diff
  )
  if line then
    return tonumber(line) or 1
  end

  local first = diff_utils.parse_unified_diff_hunks(diff)[1]
  if first then
    if (first.new_count or 0) > 0 then
      return tonumber(first.new_start) or 1
    end
    return tonumber(first.old_start) or 1
  end

  return 1
end

-- Helper: get the "current" code buffer and its window, skipping lazyagent scratch buffers.
-- Prefers the buffer tracked as lazyagent_source_bufnr (the last code buffer focused before
-- switching to the lazyagent window), then falls back to the first visible normal buffer.
local function current_buf()
  -- Check each open window for a lazyagent scratch buffer that tracks a source buffer
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    local ok, src = pcall(vim.api.nvim_buf_get_var, buf, "lazyagent_source_bufnr")
    if ok and src and vim.api.nvim_buf_is_valid(src) and vim.bo[src].buftype == "" then
      -- Find a window currently showing this source buffer
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(w) == src then
          return src, w
        end
      end
      -- Source buffer exists but is not visible; return it with a fallback win
      return src, vim.api.nvim_get_current_win()
    end
  end
  -- Fallback: first window with a normal (non-special) buffer
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    local bt = vim.bo[buf].buftype
    if bt == "" or bt == "acwrite" then
      return buf, win
    end
  end
  return vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
end

-- ────────────────────────────────────────────────
-- Tool registry
-- ────────────────────────────────────────────────

M.list = {
  -- Lifecycle / status
  {
    name = "notify_done",
    description = "Signal that the agent has finished its current task. Stops the spinner in the status bar.",
    inputSchema = {
      type = "object",
      properties = {
        agent_name = { type = "string", description = "Agent name (e.g. 'Claude'). Optional – inferred if omitted." },
      },
      required = {},
    },
    handler = function(params)
      local status = require("lazyagent.logic.status")
      local name = params.agent_name

      -- set_idle now handles SSE push internally via status.lua
      if name then
        status.set_idle(name)
      else
        for aname, s in pairs(state.sessions or {}) do
          if s.monitor_timer then status.set_idle(aname) end
        end
      end
      local hopts = (state.opts and state.opts.hooks) or {}
      local cwd = resolve_tool_cwd(params)
      local files = changed_files_since(cwd, state._hook_turn_start)
      if hook_reload_enabled() then
        reload_loaded_buffers_for_paths(cwd, files)
      end
      -- Notify changed files summary
      if hopts.notify_on_done ~= false then
        if files and #files > 0 then
          local label = #files == 1 and "1 file changed" or (#files .. " files changed")
          local names = table.concat(vim.tbl_map(function(f) return vim.fn.fnamemodify(f, ":t") end, files), ", ")
          vim.notify(label .. ": " .. names, vim.log.levels.INFO, { title = "Agent done" })
        end
      end
      -- git checkpoint
      if hopts.git_checkpoint_on_done then
        vim.fn.system(
          "git -C " .. vim.fn.shellescape(cwd)
          .. " diff --quiet 2>/dev/null || git -C " .. vim.fn.shellescape(cwd)
          .. " add -A && git -C " .. vim.fn.shellescape(cwd)
          .. " commit -m 'chore: agent checkpoint' --no-verify 2>/dev/null"
        )
      end

      -- Optionally request the agent to fix files collected in quickfix (opt-in via state.opts.hooks)
      if hopts.auto_fix_on_done == true and type(state._qf_items) == "table" and #state._qf_items > 0 then
        state._fix_requested = state._fix_requested or false
        if not state._fix_requested then
          state._fix_requested = true

          local targets = {}
          if params.agent_name and params.agent_name ~= "" then
            table.insert(targets, params.agent_name)
          else
            for aname, s in pairs(state.sessions or {}) do
              if s and s.pane_id then table.insert(targets, aname) end
            end
          end

          for _, aname in ipairs(targets) do
            local s = state.sessions and state.sessions[aname] or nil
            if s and s.pane_id then
              -- Build file list using quickfix items (absolute paths)
              local files = {}
              for _, item in ipairs(state._qf_items or {}) do
                local path = normalize_fs_path(item.filename)
                if path then table.insert(files, path) end
              end

              if #files > 0 then
                -- Build a user-style prompt that references files so ACP can embed them (@file)
                local prompt_lines = {
                  "Please fix the following files to resolve their diagnostics. Edit the files directly and make minimal, focused changes. For each file, apply fixes and then reply with a one-line summary of what you changed.",
                  "",
                  "Files:",
                }
                for _, f in ipairs(files) do table.insert(prompt_lines, "- @" .. f) end
                table.insert(prompt_lines, "")
                table.insert(prompt_lines, "-Lazyagent")
                local prompt = table.concat(prompt_lines, "\n")

                local agent_cfg = agent_logic and agent_logic.get_interactive_agent and agent_logic.get_interactive_agent(aname) or nil
                local _, backend_mod = backend_logic.resolve_backend_for_agent(aname, agent_cfg)
                if backend_mod and type(backend_mod.paste_and_submit) == "function" then
                  pcall(function()
                    backend_mod.paste_and_submit(s.pane_id, prompt, agent_cfg and agent_cfg.submit_keys or {}, { submit_delay = tonumber(hopts.fix_submit_delay_ms) or 150 })
                  end)
                end
              end
            end
          end
        end

      -- Auto-review diagnostics for quickfix items (configurable via state.opts.hooks)
      elseif hopts.diagnostic_on_done ~= false and type(state._qf_items) == "table" and #state._qf_items > 0 then
        if not state._diagnostic_loop_active then
          state._diagnostic_loop_active = true
          local items = vim.deepcopy(state._qf_items)
          local interval = tonumber(hopts.diagnostic_loop_interval_ms) or 1500
          local fetch_delay = tonumber(hopts.diagnostic_fetch_delay_ms) or 200
          local sev_map = { error = 1, warning = 2, info = 3, hint = 4, all = 4 }
          local min_sev = sev_map[tostring(hopts.diagnostic_min_severity or "all"):lower()] or 4
          local repeat_loop = hopts.diagnostic_loop_repeat == true
          local idx = 1

          local function stop_loop()
            state._diagnostic_loop_active = false
          end

          local function show_next()
            if not state._diagnostic_loop_active then return end
            if not items or #items == 0 then stop_loop(); return end
            local item = items[idx]
            if not item or not item.filename then
              idx = idx + 1
              if idx > #items then
                if repeat_loop then idx = 1 else stop_loop(); return end
              end
              vim.defer_fn(show_next, 0)
              return
            end
            local fname = item.filename
            -- Open file in current window (prefer normal window)
            pcall(vim.cmd, "edit " .. vim.fn.fnameescape(fname))
            local bufnr = vim.fn.bufnr(fname)
            if not vim.api.nvim_buf_is_loaded(bufnr) then pcall(vim.fn.bufload, bufnr) end

            -- Allow LSP/diagnostic providers to publish diagnostics
            vim.defer_fn(function()
              if not state._diagnostic_loop_active then return end
              local raw = vim.diagnostic.get(bufnr) or {}
              local filtered = {}
              for _, d in ipairs(raw) do
                if (d.severity or 4) <= min_sev then table.insert(filtered, d) end
              end
              if #filtered > 0 then
                local d = filtered[1]
                pcall(vim.api.nvim_win_set_cursor, vim.api.nvim_get_current_win(), { d.lnum + 1, d.col or 0 })
                pcall(vim.diagnostic.open_float, bufnr, { scope = "line" })
              else
                vim.notify("No diagnostics for " .. vim.fn.fnamemodify(fname, ":t"), vim.log.levels.INFO, { title = "Agent diagnostics" })
              end
              idx = idx + 1
              if idx > #items then
                if repeat_loop then idx = 1 else stop_loop(); return end
              end
              vim.defer_fn(show_next, interval)
            end, fetch_delay)
          end

          vim.defer_fn(show_next, 0)
        end
      end

      return { success = true }
    end,
  },
  {
    name = "notify_waiting",
    description = "Signal that the agent is waiting for user input. Updates the status bar accordingly.",
    inputSchema = {
      type = "object",
      properties = {
        agent_name = { type = "string" },
        message = { type = "string", description = "Optional hint shown in status bar." },
      },
      required = {},
    },
    handler = function(params)
      local status = require("lazyagent.logic.status")
      local name = params.agent_name
      local msg = params.message or "Waiting..."
      -- set_waiting now handles SSE push internally via status.lua
      if name then
        status.set_waiting(name, msg)
      else
        for aname, s in pairs(state.sessions or {}) do
          if s.monitor_timer then status.set_waiting(aname, msg) end
        end
      end
      return { success = true }
    end,
  },
  {
    name = "notify_start",
    description = "Signal that the agent has started processing. Starts the spinner in the status bar.",
    inputSchema = {
      type = "object",
      properties = {
        agent_name = { type = "string", description = "Agent name (e.g. 'Claude'). Optional – inferred if omitted." },
      },
      required = {},
    },
    handler = function(params)
      local status = require("lazyagent.logic.status")
      local name = params.agent_name
      -- start_monitor now handles SSE push internally via status.lua
      if name then
        status.start_monitor(name)
      else
        for aname, _ in pairs(state.sessions or {}) do
          pcall(function() status.start_monitor(aname) end)
        end
      end
      begin_edit_tracking(resolve_tool_cwd(params))
      return { success = true }
    end,
  },

  -- Buffer / editor context
  {
    name = "get_buffer",
    description = "Get the content of the current (or specified) Neovim buffer.",
    inputSchema = {
      type = "object",
      properties = {
        bufnr = { type = "integer", description = "Buffer number. Defaults to the current focused buffer." },
        with_line_numbers = { type = "boolean", description = "Prefix each line with its line number." },
      },
      required = {},
    },
    handler = function(params)
      local buf = params.bufnr or current_buf()
      if not vim.api.nvim_buf_is_valid(buf) then
        return nil, { code = -32602, message = "Invalid buffer: " .. tostring(buf) }
      end
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local name = vim.api.nvim_buf_get_name(buf)
      local ft = vim.bo[buf].filetype
      if params.with_line_numbers then
        for i, l in ipairs(lines) do lines[i] = string.format("%d\t%s", i, l) end
      end
      return {
        filename = name,
        filetype = ft,
        content = table.concat(lines, "\n"),
        line_count = #lines,
      }
    end,
  },
  {
    name = "get_cursor_context",
    description = "Get the current cursor position and surrounding lines for context.",
    inputSchema = {
      type = "object",
      properties = {
        context_lines = { type = "integer", description = "Lines of context above/below cursor (default 10)." },
      },
      required = {},
    },
    handler = function(params)
      local buf, win = current_buf()
      local cursor = vim.api.nvim_win_get_cursor(win)
      local row = cursor[1] -- 1-indexed
      local col = cursor[2] -- 0-indexed
      local ctx = params.context_lines or 10
      local start_line = math.max(0, row - ctx - 1)
      local end_line = math.min(vim.api.nvim_buf_line_count(buf), row + ctx)
      local lines = vim.api.nvim_buf_get_lines(buf, start_line, end_line, false)
      return {
        filename = vim.api.nvim_buf_get_name(buf),
        filetype = vim.bo[buf].filetype,
        cursor_line = row,
        cursor_col = col + 1,
        context_start_line = start_line + 1,
        content = table.concat(lines, "\n"),
      }
    end,
  },
  {
    name = "list_buffers",
    description = "List all open Neovim buffers with their metadata.",
    inputSchema = {
      type = "object",
      properties = {
        only_listed = { type = "boolean", description = "If true, only return listed buffers (default: true)." },
      },
      required = {},
    },
    handler = function(params)
      local only_listed = params.only_listed ~= false
      local buffers = {}
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        local listed = vim.fn.buflisted(buf) == 1
        if not only_listed or listed then
          table.insert(buffers, {
            bufnr = buf,
            name = vim.api.nvim_buf_get_name(buf),
            filetype = vim.bo[buf].filetype,
            modified = vim.bo[buf].modified,
            listed = listed,
            loaded = vim.api.nvim_buf_is_loaded(buf),
          })
        end
      end
      return { buffers = buffers }
    end,
  },

  -- LSP
  {
    name = "get_diagnostics",
    description = "Get LSP diagnostics (errors, warnings, hints) for the current or specified buffer.",
    inputSchema = {
      type = "object",
      properties = {
        bufnr = { type = "integer", description = "Buffer number. Defaults to current buffer." },
        severity = {
          type = "string",
          enum = { "error", "warning", "info", "hint", "all" },
          description = "Minimum severity to include (default: 'all').",
        },
      },
      required = {},
    },
    handler = function(params)
      local buf = params.bufnr or current_buf()
      if not vim.api.nvim_buf_is_valid(buf) then
        return nil, { code = -32602, message = "Invalid buffer" }
      end
      local sev_map = { error = 1, warning = 2, info = 3, hint = 4 }
      local min_sev = sev_map[params.severity] or 4
      local raw = vim.diagnostic.get(buf)
      local results = {}
      for _, d in ipairs(raw) do
        if (d.severity or 4) <= min_sev then
          table.insert(results, {
            line = d.lnum + 1,
            col = d.col + 1,
            severity = ({ [1] = "error", [2] = "warning", [3] = "info", [4] = "hint" })[d.severity] or "hint",
            message = d.message,
            source = d.source,
          })
        end
      end
      table.sort(results, function(a, b)
        if a.severity ~= b.severity then return a.severity < b.severity end
        return a.line < b.line
      end)
      return {
        filename = vim.api.nvim_buf_get_name(buf),
        diagnostics = results,
        count = #results,
      }
    end,
  },
  {
    name = "get_hover",
    description = "Get LSP hover information (type, docs) for the symbol at the cursor.",
    inputSchema = { type = "object", properties = vim.empty_dict(), required = {} },
    handler = function(_)
      -- We capture the hover result synchronously via a temporary handler
      local result_holder = {}
      local done = false
      local buf, win = current_buf()
      local client = vim.lsp.get_clients({ bufnr = buf })[1]
      local enc = client and client.offset_encoding or "utf-16"
      local params = vim.lsp.util.make_position_params(win, enc)
      vim.lsp.buf_request(buf, "textDocument/hover", params, function(_, result)
        if result and result.contents then
          local content = vim.lsp.util.convert_input_to_markdown_lines(result.contents)
          result_holder.content = table.concat(content, "\n")
        end
        done = true
      end)
      -- Wait up to 1s
      local luv = vim.loop
      local deadline = luv and (luv.now() + 1000) or nil
      if deadline then
        while not done and luv.now() < deadline do
          luv.run("once")
        end
      end
      if result_holder.content then
        return { hover = result_holder.content }
      else
        return { hover = nil, message = "No hover info available" }
      end
    end,
  },
  {
    name = "get_lsp_symbols",
    description = "Get LSP symbols (functions, variables, etc.) for the current or specified buffer.",
    inputSchema = {
      type = "object",
      properties = {
        bufnr = { type = "integer", description = "Buffer number. Defaults to current buffer." },
      },
      required = {},
    },
    handler = function(params)
      local buf = params.bufnr or current_buf()
      if not vim.api.nvim_buf_is_valid(buf) then
        return nil, { code = -32602, message = "Invalid buffer" }
      end
      local result_holder = {}
      local done = false
      vim.lsp.buf_request(buf, "textDocument/documentSymbol", { textDocument = vim.lsp.util.make_text_document_params(buf) }, function(_, result)
        if result then result_holder.symbols = result end
        done = true
      end)
      -- Wait up to 1s
      local deadline = (vim.loop or vim.uv).now() + 1000
      while not done and (vim.loop or vim.uv).now() < deadline do
        (vim.loop or vim.uv).run("once")
      end
      return { symbols = result_holder.symbols or {}, count = #(result_holder.symbols or {}) }
    end,
  },
  {
    name = "get_lsp_definitions",
    description = "Get LSP definition locations for the symbol at the cursor.",
    inputSchema = { type = "object", properties = vim.empty_dict(), required = {} },
    handler = function(_)
      local buf, win = current_buf()
      local client = vim.lsp.get_clients({ bufnr = buf })[1]
      local enc = client and client.offset_encoding or "utf-16"
      local params = vim.lsp.util.make_position_params(win, enc)
      local result_holder = {}
      local done = false
      vim.lsp.buf_request(buf, "textDocument/definition", params, function(_, result)
        if result then result_holder.definitions = result end
        done = true
      end)
      -- Wait up to 1s
      local deadline = (vim.loop or vim.uv).now() + 1000
      while not done and (vim.loop or vim.uv).now() < deadline do
        (vim.loop or vim.uv).run("once")
      end
      -- result might be a list or a single Location
      local definitions = result_holder.definitions or {}
      if type(definitions) == "table" and definitions.uri then
        definitions = { definitions } -- Wrap single location
      end
      return { definitions = definitions }
    end,
  },

  -- File operations
  {
    name = "open_file",
    description = "Open a file in Neovim.",
    inputSchema = {
      type = "object",
      properties = {
        path = { type = "string", description = "Absolute or relative path to the file." },
        line = { type = "integer", description = "Line number to jump to (optional)." },
        column = { type = "integer", description = "Column number to jump to (optional)." },
      },
      required = { "path" },
    },
    handler = function(params)
      if not params.path or params.path == "" then
        return nil, { code = -32602, message = "path is required" }
      end
      local path = vim.fn.expand(params.path)
      vim.cmd("edit " .. vim.fn.fnameescape(path))

      -- Buffer and window selection
      local bufnr = vim.fn.bufnr(path)
      local current_bufnr = vim.api.nvim_get_current_buf()
      local is_lazy = (vim.bo[current_bufnr].filetype == "lazyagent")
      local target_win = nil

      if is_lazy then
        -- If we're in the lazyagent scratch window, prefer opening in a normal window.
        local _, nw = current_buf()
        target_win = nw or vim.api.nvim_get_current_win()
      else
        for _, w in ipairs(vim.api.nvim_list_wins()) do
          local b = vim.api.nvim_win_get_buf(w)
          if b == bufnr then target_win = w; break end
        end
        if not target_win then target_win = vim.api.nvim_get_current_win() end
      end

      -- Determine line/column: prefer explicit params, fall back to last_edit recorded by write_to_buffer
      local line = params.line
      local col = params.column or 0
      if not line then
        local ok, last = pcall(vim.api.nvim_buf_get_var, bufnr, 'lazyagent_last_edit_line')
        if ok and last then line = last end
      end

      if line then pcall(function() vim.api.nvim_win_set_cursor(target_win, { line, col }) end) end

      return { success = true, path = path }
    end,
  },
  {
    name = "open_last_changed",
    description = "Open the most recently modified file in the current project (detected via git) and jump to the changed line. Call this after editing files.",
    inputSchema = {
      type = "object",
      properties = {
        agent_name = { type = "string", description = "Agent session name used to resolve the project root." },
        cwd = { type = "string", description = "Working directory used to resolve relative paths." },
        path = { type = "string", description = "Explicit changed file path. When omitted, lazyagent infers the latest changed file." },
        oldText = { type = "string", description = "Before-edit content for matching the changed hunk." },
        newText = { type = "string", description = "After-edit content for matching the changed hunk." },
      },
      required = {},
    },
    handler = function(_params)
      local hopts = (state.opts and state.opts.hooks) or {}
      local cwd = resolve_tool_cwd(_params)
      local newest_path = nil

      -- Build set of paths already in quickfix this turn
      state._qf_items = state._qf_items or {}
      local in_qf = {}
      for _, item in ipairs(state._qf_items) do
        in_qf[item.filename] = true
      end

      if _params.path and _params.path ~= "" then
        newest_path = resolve_target_path(_params.path, cwd)
        if not newest_path then
          return nil, { code = -32602, message = "Invalid path: " .. tostring(_params.path) }
        end
      else
        -- Get files changed during this agent turn
        local files = changed_files_since(cwd, state._hook_turn_start)
        if not files or #files == 0 then
          return { success = false, message = "No changed files found in " .. cwd }
        end

        -- Among files NOT yet in quickfix, pick the one with highest mtime
        -- (>= so last-in-list wins on tie, giving progress across hook calls)
        local newest_mtime = -1
        for _, rel in ipairs(files) do
          local abs = resolve_target_path(rel, cwd)
          if abs and not in_qf[abs] then
            local mtime = vim.fn.getftime(abs)
            if mtime >= newest_mtime then
              newest_mtime = mtime
              newest_path = abs
            end
          end
        end

        -- All files already registered this turn – nothing to do
        if not newest_path then
          return { success = true, message = "All changed files already in quickfix" }
        end
      end

      local line = changed_line_from_diff(cwd, newest_path, _params)

      -- Append to quickfix (dedup handled via in_qf above)
      if hopts.quickfix_on_edit ~= false and not in_qf[newest_path] then
        table.insert(state._qf_items, { filename = newest_path, lnum = line, col = 1, text = "agent edited" })
        vim.fn.setqflist({}, "r", { title = "Agent turn", items = state._qf_items })
      end

      if hopts.open_on_edit ~= true then
        return {
          success = true,
          path = newest_path,
          line = line,
        }
      end

      -- Focus a normal (non-lazyagent) window BEFORE opening the file,
      -- so vim.cmd("edit") doesn't land in the scratch window.
      local _, target_win = current_buf()
      if target_win then
        pcall(vim.api.nvim_set_current_win, target_win)
      end

      -- Open file and jump to line
      vim.cmd("edit " .. vim.fn.fnameescape(newest_path))
      local bufnr = vim.fn.bufnr(newest_path)
      -- Refresh target_win in case it changed after edit
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(w) == bufnr then target_win = w; break end
      end
      pcall(vim.api.nvim_win_set_cursor, target_win or vim.api.nvim_get_current_win(), { line, 0 })

      return {
        success = true,
        path = newest_path,
        line = line,
      }
    end,
  },
  {
    name = "write_to_buffer",
    description = "Append or replace content in the current Neovim buffer (or a specified scratch buffer).",
    inputSchema = {
      type = "object",
      properties = {
        content = { type = "string", description = "Text to write." },
        bufnr = { type = "integer", description = "Target buffer number. Defaults to current buffer." },
        mode = {
          type = "string",
          enum = { "append", "replace" },
          description = "Whether to append or replace existing content (default: append).",
        },
      },
      required = { "content" },
    },
    handler = function(params)
      local buf = params.bufnr or current_buf()
      if not vim.api.nvim_buf_is_valid(buf) then
        return nil, { code = -32602, message = "Invalid buffer" }
      end
      local lines = vim.split(params.content or "", "\n", { plain = true })
      local mode = params.mode or "append"
      local start_line = 1
      if mode == "replace" then
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        start_line = 1
      else
        local count = vim.api.nvim_buf_line_count(buf)
        vim.api.nvim_buf_set_lines(buf, count, count, false, lines)
        start_line = count + 1
      end
      -- Record last edit line for this buffer so open_file can fallback to it when no line is provided
      pcall(vim.api.nvim_buf_set_var, buf, 'lazyagent_last_edit_line', start_line)
      return { success = true, lines_written = #lines, last_edit_line = start_line }
    end,
  },
  {
    name = "run_command",
    description = "Execute a Neovim command (e.g., ':write').",
    inputSchema = {
      type = "object",
      properties = {
        command = { type = "string", description = "The Neovim command to execute." },
      },
      required = { "command" },
    },
    handler = function(params)
      local ok, result = pcall(vim.api.nvim_command, params.command)
      if not ok then
        return nil, { code = -32603, message = "Command failed: " .. tostring(result) }
      end
      return { success = true, result = result }
    end,
  },
  {
    name = "run_lua",
    description = "Execute arbitrary Lua code in the Neovim environment.",
    inputSchema = {
      type = "object",
      properties = {
        code = { type = "string", description = "Lua code snippet." },
      },
      required = { "code" },
    },
    handler = function(params)
      local f, err = loadstring(params.code)
      if not f then
        return nil, { code = -32602, message = "Lua compilation error: " .. tostring(err) }
      end
      local ok, result = pcall(f)
      if not ok then
        return nil, { code = -32603, message = "Lua execution failed: " .. tostring(result) }
      end
      return { success = true, result = result }
    end,
  },
  {
    name = "list_files",
    description = "List files and directories in a given path.",
    inputSchema = {
      type = "object",
      properties = {
        path = { type = "string", description = "The directory path to list. Defaults to current directory." },
      },
      required = {},
    },
    handler = function(params)
      local path = vim.fn.expand(params.path or ".")
      local entries = {}
      local handle = vim.loop.fs_scandir(path)
      if not handle then
        return nil, { code = -32602, message = "Could not open directory: " .. path }
      end
      while true do
        local name, type = vim.loop.fs_scandir_next(handle)
        if not name then break end
        table.insert(entries, { name = name, type = type })
      end
      return { path = path, entries = entries }
    end,
  },
  {
    name = "grep_search",
    description = "Search for a pattern in files within a directory (limited to 100 results).",
    inputSchema = {
      type = "object",
      properties = {
        pattern = { type = "string", description = "The pattern to search for." },
        path = { type = "string", description = "The directory to search in. Defaults to current directory." },
      },
      required = { "pattern" },
    },
    handler = function(params)
      local path = vim.fn.expand(params.path or ".")
      local cmd = string.format("grep -rIn --exclude-dir=.git %s %s", vim.fn.shellescape(params.pattern), vim.fn.shellescape(path))
      if vim.fn.executable("rg") == 1 then
        cmd = string.format("rg --column --line-number --no-heading --color=never --smart-case -- %s %s", vim.fn.shellescape(params.pattern), vim.fn.shellescape(path))
      end
      local handle = io.popen(cmd)
      if not handle then return { results = {} } end
      local results = {}
      for _ = 1, 100 do
        local line = handle:read("*l")
        if not line then break end
        table.insert(results, line)
      end
      handle:close()
      return { pattern = params.pattern, path = path, results = results, count = #results }
    end,
  },
  -- ── Remote / WebUI tools ─────────────────────────────────────────
  {
    name = "send_key",
    description = "Send a special key (Up, Down, Enter, Escape, C-c, etc.) to the active agent's terminal pane.",
    inputSchema = {
      type = "object",
      properties = {
        key = { type = "string", description = "Key to send: 'Up', 'Down', 'Enter', 'Escape', 'C-c', etc." },
        agent_name = { type = "string", description = "Agent name. Defaults to the current open agent." },
      },
      required = { "key" },
    },
    handler = function(params)
      local key = params.key
      if not key or key == "" then
        return nil, { code = -32602, message = "'key' is required" }
      end
      local agent_name = params.agent_name
      if agent_name and agent_name ~= "" then
        local backend_logic = require("lazyagent.logic.backend")
        local s = state.sessions[agent_name]
        if not s or not s.pane_id then
          return nil, { code = -32602, message = "No pane for agent: " .. agent_name }
        end
        local _, backend_mod = backend_logic.resolve_backend_for_agent(agent_name, nil)
        backend_mod.send_keys(s.pane_id, { key })
      else
        local send = require("lazyagent.logic.send")
        if key == "Enter" then
          send.send_enter()
        elseif key == "Up" then
          send.send_up()
        elseif key == "Down" then
          send.send_down()
        else
          send.send_key(key)
        end
      end
      return { success = true }
    end,
  },
  {
    name = "send_to_agent",
    description = "Send a text prompt to an interactive agent (CLI session). Starts or reuses the agent session.",
    inputSchema = {
      type = "object",
      properties = {
        text = { type = "string", description = "The prompt/text to send." },
        agent_name = { type = "string", description = "Agent name (e.g. 'Copilot'). Defaults to the current open agent." },
      },
      required = { "text" },
    },
    handler = function(params)
      if not params.text or #params.text == 0 then
        return nil, { code = -32602, message = "'text' is required" }
      end
      local send = require("lazyagent.logic.send")
      send.send_to_cli(params.agent_name or "", params.text)
      return { success = true }
    end,
  },
  {
    name = "get_agent_status",
    description = "Get the current status of all configured interactive agents (thinking/idle/waiting/no_session).",
    inputSchema = {
      type = "object",
      properties = {
        agent_name = { type = "string", description = "Agent name to query. If omitted, returns all configured agents." },
      },
      required = {},
    },
    handler = function(params)
      local agents = {}
      if params.agent_name and params.agent_name ~= "" then
        local s = state.sessions[params.agent_name]
        table.insert(agents, {
          name   = params.agent_name,
          status = s and (s.agent_status or "idle") or "no_session",
        })
      else
        -- All configured interactive agents
        for name, _ in pairs((state.opts and state.opts.interactive_agents) or {}) do
          local s = state.sessions[name]
          table.insert(agents, {
            name   = name,
            status = s and (s.agent_status or "idle") or "no_session",
          })
        end
        -- Also include sessions that exist but are not in config
        for name, s in pairs(state.sessions or {}) do
          local seen = false
          for _, a in ipairs(agents) do
            if a.name == name then seen = true; break end
          end
          if not seen then
            table.insert(agents, { name = name, status = s.agent_status or "idle" })
          end
        end
        table.sort(agents, function(a, b) return a.name < b.name end)
      end
      return { agents = agents }
    end,
  },
  {
    name = "get_terminal_capture",
    description = "Get a plain-text capture of an agent's terminal pane (tmux scrollback).",
    inputSchema = {
      type = "object",
      properties = {
        agent_name = { type = "string", description = "Agent name. Defaults to the current open agent or first active session." },
      },
      required = {},
    },
    handler = function(params)
      local name = params.agent_name
      if not name or name == "" then name = state.open_agent end
      if not name then
        for n, _ in pairs(state.sessions or {}) do name = n; break end
      end
      if not name then
        return nil, { code = -32602, message = "No active agent session" }
      end
      local s = state.sessions[name]
      if not s or not s.pane_id then
        return nil, { code = -32602, message = "No pane for agent: " .. tostring(name) }
      end
      local _, backend_mod = backend_logic.resolve_backend_for_agent(name, nil)
      if not backend_mod or type(backend_mod.capture_pane_sync) ~= "function" then
        return nil, { code = -32602, message = "Backend does not support capture for agent: " .. tostring(name) }
      end
      local text = backend_mod.capture_pane_sync(s.pane_id)
      return { agent_name = name, text = text }
    end,
  },
}

-- Build a name→tool map for fast dispatch
M._by_name = {}
for _, tool in ipairs(M.list) do
  M._by_name[tool.name] = tool
end

function M.call(name, params)
  local tool = M._by_name[name]
  if not tool then
    return nil, { code = -32601, message = "Unknown tool: " .. tostring(name) }
  end
  local ok, result, err = pcall(tool.handler, params or {})
  if not ok then
    return nil, { code = -32603, message = "Internal error: " .. tostring(result) }
  end
  return result, err
end

return M
