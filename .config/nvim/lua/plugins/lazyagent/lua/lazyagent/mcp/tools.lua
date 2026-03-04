-- lazyagent/mcp/tools.lua
-- MCP tool implementations exposed to agents via the MCP server.
-- Each tool has: description, inputSchema, and a handler(params) -> result | error

local M = {}
local state = require("lazyagent.logic.state")

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
      if name then
        status.set_idle(name)
      else
        -- stop all active monitors
        for aname, s in pairs(state.sessions or {}) do
          if s.monitor_timer then status.set_idle(aname) end
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
      if name then
        status.start_monitor(name)
      else
        for aname, _ in pairs(state.sessions or {}) do
          pcall(function() status.start_monitor(aname) end)
        end
      end
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
    inputSchema = { type = "object", properties = {} },
    handler = function(_params)
      local cwd = vim.fn.getcwd()

      -- Get changed files from git status
      local files = vim.fn.systemlist(
        "git -C " .. vim.fn.shellescape(cwd) .. " status --short 2>/dev/null | awk '{print $NF}'"
      )
      if not files or #files == 0 then
        return nil, { code = -32602, message = "No changed files found in " .. cwd }
      end

      -- Pick most recently modified by mtime
      local newest_mtime, newest_path = 0, nil
      for _, rel in ipairs(files) do
        local abs = cwd .. "/" .. rel
        local mtime = vim.fn.getftime(abs)
        if mtime > newest_mtime then
          newest_mtime = mtime
          newest_path = abs
        end
      end
      if not newest_path then
        return nil, { code = -32602, message = "Could not resolve file path" }
      end

      -- Find changed line from git diff hunk header
      local diff = vim.fn.systemlist(
        "git -C " .. vim.fn.shellescape(cwd)
        .. " diff --unified=0 -- " .. vim.fn.shellescape(newest_path)
        .. " 2>/dev/null | grep '^@@' | tail -1"
      )
      local line = 1
      if diff and #diff > 0 then
        local m = diff[1]:match("%+(%d+)")
        if m then line = tonumber(m) end
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

      return { success = true, path = newest_path, line = line }
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
