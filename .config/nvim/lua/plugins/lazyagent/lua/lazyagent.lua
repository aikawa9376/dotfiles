-- lazyagent.lua - Main entry point for the LazyAgent plugin.
-- This file orchestrates the various modules that comprise the plugin's functionality.

local M = require("lazyagent.logic.state")

local cache_logic = require("lazyagent.logic.cache")
local commands_logic = require("lazyagent.logic.commands")
local agent_logic = require("lazyagent.logic.agent")
local session_logic = require("lazyagent.logic.session")
local send_logic = require("lazyagent.logic.send")
local backend_logic = require("lazyagent.logic.backend")
local status_logic = require("lazyagent.logic.status")

-- Expose public API from logic modules through the main M table
M.open_history = cache_logic.open_history
M.get_active_agents = agent_logic.get_active_agents
M.send_to_cli = send_logic.send_to_cli
M.close_session = session_logic.close_session
M.close_all_sessions = session_logic.close_all_sessions
M.toggle_session = session_logic.toggle_session
M.open_instant = session_logic.open_instant
M.attach_session = session_logic.attach_session
M.send_visual = send_logic.send_visual
M.send_line = send_logic.send_line
M.status = status_logic.get_status
M.send_enter = send_logic.send_enter
M.send_down = send_logic.send_down
M.send_up = send_logic.send_up
M.send_key = send_logic.send_key
M.send_interrupt = send_logic.send_interrupt
M.send_raw_keys = send_logic.send_raw_keys
M.clear_input = send_logic.clear_input

-- Write MCP config into each agent's settings file so they auto-connect.
-- Writes lazyagent MCP config into agent settings files (JSON) and generates
-- agent-specific markdown context files in the cache directory.
-- Agents are launched with a per-agent flag (e.g. --include-directories) pointing
-- to the cache dir so they pick up the markdown file automatically.
-- The source instructions live in `<cache>/lazyagent.md` (user-editable).
-- Called once after the MCP server is ready; rewrites on every nvim start.
local function default_instructions_content()
  -- Try multiple known locations for an external default_instructions.md
  local paths = {}
  -- 1) resources/ subdir of this module's directory
  pcall(function()
    local info = debug.getinfo(default_instructions_content, "S")
    local src = info and info.source
    if src and src:sub(1,1) == "@" then src = src:sub(2) end
    local dir = src and src:match("(.*/)")
    if dir then table.insert(paths, dir .. "lazyagent/resources/default_instructions.md") end
  end)
  -- 2) fallback to standard config path layout
  pcall(function()
    table.insert(paths, vim.fn.stdpath("config") .. "/lua/plugins/lazyagent/lua/lazyagent/resources/default_instructions.md")
  end)
  -- 3) fallback to cache dir (unlikely but harmless)
  pcall(function()
    table.insert(paths, vim.fn.stdpath("cache") .. "/lazyagent/default_instructions.md")
  end)

  for _, md in ipairs(paths) do
    local f = io.open(md, "r")
    if f then
      local s = f:read("*a")
      f:close()
      if s and s ~= "" then return s end
    end
  end

  return ""
end

-- Resolve directory of this module (→ .../lua/) for locating hook templates
local _module_dir = (function()
  local info = debug.getinfo(1, "S")
  local src = info and info.source
  if src and src:sub(1, 1) == "@" then src = src:sub(2) end
  return (src and src:match("(.*/)" )) or ""
end)()

-- Copy hook scripts from source templates into agent_dir/hooks/
local function copy_hook_scripts(agent_dir)
  local src_dir = _module_dir .. "lazyagent/resources/hooks"
  pcall(vim.fn.mkdir, agent_dir .. "/hooks", "p")
  for _, name in ipairs({ "notify-start.sh", "notify-done.sh", "open-file.sh" }) do
    local fh = io.open(src_dir .. "/" .. name, "r")
    if fh then
      local content = fh:read("*a")
      fh:close()
      local fw = io.open(agent_dir .. "/hooks/" .. name, "w")
      if fw then fw:write(content); fw:close() end
      os.execute("chmod +x " .. vim.fn.shellescape(agent_dir .. "/hooks/" .. name))
    end
  end
end

local function write_mcp_configs(url, opts)
  local cache_dir = (opts and opts.cache and opts.cache.dir) or (vim.fn.stdpath("cache") .. "/lazyagent")
  vim.fn.mkdir(cache_dir, "p")

  local instructions = default_instructions_content()

  -- Write per-agent cache directories under <cache>/agents/<agent>/
  -- Each agent gets only the files it actually reads:
  --   All agents : AGENTS.md  (Copilot: via COPILOT_CUSTOM_INSTRUCTIONS_DIRS; Gemini: source for system.md)
  --   Copilot    : mcp-config.json (merged with user config, passed via --additional-mcp-config)
  for name, _ in pairs((opts and opts.interactive_agents) or {}) do
    local lname = string.lower(name)
    local agent_dir = cache_dir .. "/agents/" .. lname
    pcall(vim.fn.mkdir, agent_dir, "p")

    -- AGENTS.md: primary instruction file for all agents
    if instructions ~= "" then
      local fa = io.open(agent_dir .. "/AGENTS.md", "w")
      if fa then fa:write(instructions); fa:close() end
    end

    -- Copilot: merge user's existing mcp-config.json entries with lazyagent MCP server
    if lname == "copilot" then
      local candidates = {}
      local cop_env = vim.fn.expand("$COPILOT_CONFIG_DIR")
      if cop_env and cop_env ~= "$COPILOT_CONFIG_DIR" and cop_env ~= "" then
        table.insert(candidates, cop_env .. "/mcp-config.json")
      end
      table.insert(candidates, vim.fn.expand("~/.config/.copilot/mcp-config.json"))
      table.insert(candidates, vim.fn.expand("~/.config/copilot/mcp-config.json"))
      table.insert(candidates, vim.fn.expand("~/.copilot/mcp-config.json"))

      local merged = {}
      for _, p in ipairs(candidates) do
        local fh = io.open(p, "r")
        if fh then
          local ok, parsed = pcall(vim.fn.json_decode, fh:read("*a"))
          fh:close()
          if ok and type(parsed) == "table" then
            for k, v in pairs(parsed) do
              if type(v) == "table" and type(merged[k]) == "table" then
                for kk, vv in pairs(v) do merged[k][kk] = vv end
              else
                merged[k] = v
              end
            end
          end
        end
      end

      merged.mcpServers = merged.mcpServers or {}
      merged.mcpServers.lazyagent = {
        type = ((opts and opts._mcp_type) or "http"),
        url = (((opts and opts._mcp_type) == "unix") and ("unix:" .. url) or url),
      }

      local cm = io.open(agent_dir .. "/mcp-config.json", "w")
      if cm then cm:write(vim.fn.json_encode(merged)); cm:close() end

      -- Write MCP URL for hook scripts (read at runtime by the scripts)
      local mcp_url = (opts and opts._mcp_url) or url
      local fu = io.open(agent_dir .. "/mcp.url", "w")
      if fu then fu:write(mcp_url); fu:close() end

      -- plugin.json (required entry point for --plugin-dir; hooks.json is the actual hook config)
      local fp = io.open(agent_dir .. "/plugin.json", "w")
      if fp then
        fp:write(vim.fn.json_encode({
          name = "lazyagent-hooks",
          description = "LazyAgent Neovim integration hooks",
          version = "0.0.1",
          hooks = "hooks.json",
        }))
        fp:close()
      end

      -- Copy hook scripts from source templates
      copy_hook_scripts(agent_dir)

      -- hooks.json
      local hooks_json = vim.fn.json_encode({
        version = 1,
        hooks = {
          userPromptSubmitted = { { type = "command", bash = "./hooks/notify-start.sh", timeoutSec = 10 } },
          agentStop            = { { type = "command", bash = "./hooks/notify-done.sh",  timeoutSec = 10 } },
          postToolUse          = { { type = "command", bash = "./hooks/open-file.sh",    timeoutSec = 10 } },
        },
      })
      local fj = io.open(agent_dir .. "/hooks.json", "w")
      if fj then fj:write(hooks_json); fj:close() end

    elseif lname == "gemini" then
      -- Write MCP URL for hook scripts (read at runtime by the scripts)
      local mcp_url = (opts and opts._mcp_url) or url
      local fu = io.open(agent_dir .. "/mcp.url", "w")
      if fu then fu:write(mcp_url); fu:close() end

      -- Copy hook scripts from source templates
      copy_hook_scripts(agent_dir)

    elseif lname == "cursor" then
      local mcp_url = (opts and opts._mcp_url) or url

      -- Write mcp.url for hook scripts
      local fu = io.open(agent_dir .. "/mcp.url", "w")
      if fu then fu:write(mcp_url); fu:close() end

      -- Copy shared hook scripts
      copy_hook_scripts(agent_dir)

      -- Merge lazyagent entry into ~/.cursor/mcp.json for this session
      local cursor_cfg_path = vim.fn.expand("~/.cursor/mcp.json")
      local cfg = {}
      local fh = io.open(cursor_cfg_path, "r")
      if fh then
        local ok, parsed = pcall(vim.fn.json_decode, fh:read("*a"))
        fh:close()
        if ok and type(parsed) == "table" then cfg = parsed end
      end
      cfg.mcpServers = cfg.mcpServers or {}
      cfg.mcpServers.lazyagent = { url = mcp_url, type = "http" }
      local fw = io.open(cursor_cfg_path, "w")
      if fw then fw:write(vim.fn.json_encode(cfg)); fw:close() end

      -- Merge lazyagent hooks into ~/.cursor/hooks.json
      -- Cursor reads hooks.json from ~/.cursor/ and [project]/.cursor/
      -- We use the global one so it works regardless of project.
      local hooks_cfg_path = vim.fn.expand("~/.cursor/hooks.json")
      local hcfg = {}
      local hf = io.open(hooks_cfg_path, "r")
      if hf then
        local ok, parsed = pcall(vim.fn.json_decode, hf:read("*a"))
        hf:close()
        if ok and type(parsed) == "table" then hcfg = parsed end
      end
      hcfg.version = 1
      hcfg.hooks = hcfg.hooks or {}
      -- beforeSubmitPrompt → notify_start
      local start_cmd = agent_dir .. "/hooks/notify-start.sh"
      hcfg.hooks.beforeSubmitPrompt = hcfg.hooks.beforeSubmitPrompt or {}
      table.insert(hcfg.hooks.beforeSubmitPrompt, { command = start_cmd, id = "lazyagent-notify-start" })
      -- afterFileEdit → open_last_changed
      local edit_cmd = agent_dir .. "/hooks/open-file.sh"
      hcfg.hooks.afterFileEdit = hcfg.hooks.afterFileEdit or {}
      table.insert(hcfg.hooks.afterFileEdit, { command = edit_cmd, id = "lazyagent-open-file" })
      -- stop → notify_done
      local done_cmd = agent_dir .. "/hooks/notify-done.sh"
      hcfg.hooks.stop = hcfg.hooks.stop or {}
      table.insert(hcfg.hooks.stop, { command = done_cmd, id = "lazyagent-notify-done" })
      local hfw = io.open(hooks_cfg_path, "w")
      if hfw then hfw:write(vim.fn.json_encode(hcfg)); hfw:close() end
    end
  end
end

--- Sets up the LazyAgent plugin with user-defined options.
-- @param opts (table|nil) User options to merge with defaults.
function M.setup(opts)
  local default_opts = {
    filetype_settings = {
      ["*"] = { agent = "Gemini" },
    },
    prompts = {
      default_agent = function(context)
        vim.notify("Agent received: " .. (context and context.text or ""))
      end,
    },
    interactive_agents = (function()
      local base = {
        pane_size = "60", -- Default to fixed 60 cells width
        scratch_filetype = "lazyagent",
        -- Edit here to override agent-specific settings
        -- submit_keys = { "C-m" },
        -- submit_delay = 600,
        -- submit_retry = 1,
        is_vertical = true,
        yolo = false,
        yolo_flag = nil,
        default = false,
      }
      return {
        Claude = vim.tbl_deep_extend("force", base, {
          cmd = "claude",
          yolo_flag = "--dangerously-skip-permissions",
        }),
        Codex = vim.tbl_deep_extend("force", base, {
          cmd = "codex",
          yolo_flag = "--full-auto",
        }),
        Gemini = vim.tbl_deep_extend("force", base, {
          cmd = "gemini",
          yolo_flag = "--yolo",
        }),
        Copilot = vim.tbl_deep_extend("force", base, {
          cmd = "copilot",
          yolo_flag = "--yolo --allow-all-tools",
          -- Copilot's TUI (Bubble Tea) pauses input handling after a focus-out event.
          -- Sending \e[I (focus-in) before each send restores normal input processing.
          refocus_on_send = true,
        }),
        Cursor = vim.tbl_deep_extend("force", base, {
          cmd = "cursor-agent",
          yolo_flag = "--yolo",
        }),
      }
    end)(),
    start_in_insert_on_focus = false,
    window_type = "float",
    backend = "tmux",
    tmux_auto_exit_copy_mode = true,
    submit_delay = 600,
    submit_retry = 1,
    debug = false,
    close_on_send = true,
    save_conversation_on_close = true,
    open_conversation_on_save = false,
    scratch_keymaps = {
      close = "q",
      send_and_clear = "<C-Space>",
      send_key_insert = "<C-s>",
      send_key_normal = "<CR>",
      scroll_up = "<C-u>",
      scroll_down = "<C-d>",
      nav_up = "<Up>",
      nav_down = "<Down>",
      esc = "<Esc>",
      clear = "c<space>d",
      history_next = "c<space>n",
      history_prev = "c<space>p",
    },
    cache = {
      enabled = true,
      dir = vim.fn.stdpath("cache") .. "/lazyagent",
      debounce_ms = 1500,
      max_history = 100,
      -- Automatically delete conversation log files older than this duration on startup.
      -- Format: "<number><unit>" where unit is h (hours), d (days), w (weeks), m (months).
      -- Set to nil or "" to disable.
      conversation_retention = "30d",
    },
    -- How new content is merged into existing agent input:
    -- - "append": move cursor to end of agent's input and append content before submitting.
    -- - "replace": wipe existing input and paste-the-new content.
    send_mode = "append",
    -- If true, wrap pasted blocks with the terminal "bracketed paste" control chars
    -- to preserve pasted content as one operation in supported terminals.
    use_bracketed_paste = true,
    send_number_keys_to_agent = true,
    resume = false,
    -- MCP mode: start a Streamable HTTP MCP server inside Neovim.
    -- Agents that support MCP can connect to it to get LSP diagnostics,
    -- buffer contents, and signal task completion (notify_done/notify_waiting).
    -- Set to true and configure your agent to connect to LAZYAGENT_MCP_URL.
    mcp_mode = true,
    -- Text sent to the agent pane on first launch when mcp_mode is enabled.
    -- Instructs the agent to call notify_done/notify_waiting via MCP.
    -- Overridable per-agent via interactive_agents[name].initial_send.
    -- Set to false or "" to disable for all agents (default: false, use file-based approach instead).
    mcp_initial_send = false,
    -- Delay (ms) before sending initial_send after agent launch (default 3000).
    -- Increase if your agent CLI takes longer to start.
    initial_send_delay = 3000,
    -- Best-effort interrupts: send Ctrl-C to agent panes before killing them when closing Neovim.
    -- Tunable via `interrupt_attempts` and `interrupt_interval_ms` in setup(opts).
    interrupt_attempts = 3,
    interrupt_interval_ms = 40,
    -- Hook behaviour (requires mcp_mode = true; ignored otherwise):
    hooks = {
      -- Open the most recently changed file after each agent edit tool.
      open_on_edit = true,
      -- Populate quickfix with all git-changed files in real-time on each agent edit.
      quickfix_on_edit = true,
      -- Show a vim.notify summary of changed files when the agent finishes a turn.
      notify_on_done = true,
      -- Automatically create a git commit checkpoint when the agent finishes a turn.
      git_checkpoint_on_done = false,
    },
    -- Options specific to Instant Mode
    instant_mode = {
      append_text = nil, -- e.g. " #translate"
    },
  }

  M.opts = vim.tbl_deep_extend("force", default_opts, opts or {})

  -- Register any backend modules passed through setup opts (backends[name]={module} OR backends[name]="lua.module.path")
  if M.opts.backends and type(M.opts.backends) == "table" then
    for name, mod in pairs(M.opts.backends) do
      if type(mod) == "string" then
        local ok, loaded = pcall(require, mod)
        if ok and loaded then backend_logic.register_backend(name, loaded) end
      elseif type(mod) == "table" then
        backend_logic.register_backend(name, mod)
      end
    end
  end

  pcall(function()
    if vim and vim.treesitter and vim.treesitter.language and vim.treesitter.language.register then
      pcall(function() vim.treesitter.language.register("markdown", { "lazyagent" }) end)
    end
  end)

  if M._configured then
    return
  end
  M._configured = true

  -- Register user commands
  commands_logic.setup_commands()

  -- Close all agent sessions on Quit/Exit
  pcall(function()
    local group = vim.api.nvim_create_augroup("LazyAgentCleanup", { clear = true })
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = group,
      callback = function()
        session_logic.close_all_sessions(true)
      end,
      desc = "Close lazyagent tmux sessions on exit",
    })
  end)

  -- Helper: cleanup stale sockets and persisted sessions on startup
  local function cleanup_stale_resources(opts)
    local uv = vim.loop
    local cache_dir = (opts and opts.cache and opts.cache.dir) or (vim.fn.stdpath("cache") .. "/lazyagent")

    -- 1) Clean stale unix sockets in XDG_RUNTIME_DIR/lazyagent
    local runtime = os.getenv("XDG_RUNTIME_DIR") or vim.fn.stdpath("state")
    local sock_dir = runtime .. "/lazyagent"
    if vim.fn.isdirectory(sock_dir) == 1 then
      local ok, entries = pcall(vim.fn.readdir, sock_dir)
      if ok and type(entries) == "table" then
        for _, f in ipairs(entries) do
          if f:match("^lazyagent%-.*%.sock$") then
            local path = sock_dir .. "/" .. f
            local st = uv.fs_stat(path)
            if not st then
              pcall(function() vim.loop.fs_unlink(path) end)
            else
              -- Remove sockets older than 24h (likely stale)
              if (os.time() - st.mtime) > 24 * 3600 then
                pcall(function() vim.loop.fs_unlink(path) end)
              end
            end
          end
        end
      end
    end

    -- 2) Clean persisted tmux sessions that no longer exist
    local persistence = require("lazyagent.logic.persistence")
    local backend_logic = require("lazyagent.logic.backend")
    local data = persistence.load()
    for key, pane_id in pairs(data) do
      local agent_name, cwd = key:match("^(.-)::(.+)$")
      if agent_name then
        local _, backend_mod = backend_logic.resolve_backend_for_agent(agent_name, nil)
        local exists = false
        if backend_mod and type(backend_mod.pane_exists) == "function" then
          local ok, res = pcall(backend_mod.pane_exists, pane_id)
          exists = ok and (res == true)
        end
        if not exists then
          persistence.remove_session(agent_name, cwd)
        end
      end
    end

    -- 3) Remove stale files from agent cache dirs that are no longer generated
    local uv2 = vim.loop
    local agents_dir = cache_dir .. "/agents"
    if vim.fn.isdirectory(agents_dir) == 1 then
      local ok_a, agent_dirs = pcall(vim.fn.readdir, agents_dir)
      if ok_a and type(agent_dirs) == "table" then
        for _, aname in ipairs(agent_dirs) do
          local apath = agents_dir .. "/" .. aname
          -- <NAME>.md (e.g. COPILOT.md, GEMINI.md) replaced by AGENTS.md
          pcall(function() uv2.fs_unlink(apath .. "/" .. string.upper(aname) .. ".md") end)
          -- lazyagent.mcp.json no longer generated
          pcall(function() uv2.fs_unlink(apath .. "/lazyagent.mcp.json") end)
        end
      end
    end
    -- Remove root-level cache files that are no longer generated
    pcall(function() uv2.fs_unlink(cache_dir .. "/lazyagent.mcp.json") end)
    pcall(function() uv2.fs_unlink(cache_dir .. "/lazyagent-system-defaults.json") end)
  end

  -- Start MCP server if mcp_mode is enabled
  if M.opts.mcp_mode then
    -- Run startup cleanup to avoid accumulating stale sockets/persistence
    pcall(function() cleanup_stale_resources(M.opts) end)
    -- Purge old conversation logs based on retention setting
    pcall(function() cache_logic.purge_old_conversations() end)

    local mcp_server = require("lazyagent.mcp.server")
    local start_opts = {}
    local ok_unix = (vim.loop and vim.loop.os_uname and vim.loop.os_uname().sysname ~= "Windows_NT")

    -- Auto-assign a per-session fixed TCP port by default to provide a 1:1 HTTP endpoint
    -- (helps CLIs like Copilot that prefer an explicit HTTP URL). Falls back to a unix
    -- socket if TCP port allocation fails or on Windows.
    local function allocate_port()
      local s = vim.loop.new_tcp()
      local ok, err = pcall(function() s:bind("127.0.0.1", 0) end)
      if not ok then
        pcall(function() s:close() end)
        return nil
      end
      local addr = s:getsockname()
      local port = addr and addr.port
      pcall(function() s:close() end)
      return port
    end

    if M.opts and M.opts.mcp_fixed_port and type(M.opts.mcp_fixed_port) == "number" then
      start_opts.port = M.opts.mcp_fixed_port
    else
      if ok_unix then
        local port = allocate_port()
        if port then
          start_opts.port = port
        else
          local runtime = os.getenv("XDG_RUNTIME_DIR") or vim.fn.stdpath("state")
          local dir = runtime .. "/lazyagent"
          pcall(vim.fn.mkdir, dir, "p")
          start_opts.sock_path = dir .. "/lazyagent-" .. tostring(vim.fn.getpid()) .. ".sock"
        end
      end
    end

    if start_opts.port then start_opts.sock_path = nil end

    -- If mcp_host is set (e.g. "0.0.0.0" for LAN access), pass it through
    if M.opts.mcp_host then
      start_opts.host = M.opts.mcp_host
    end

    local uv = vim.loop
    local sig_int, sig_term
    local function register_signal_handlers(mcp_stop)
      if not uv.new_signal then return end
      sig_int = uv.new_signal()
      sig_term = uv.new_signal()
      sig_int:start("sigint", function() pcall(mcp_stop) end)
      sig_term:start("sigterm", function() pcall(mcp_stop) end)
    end

    mcp_server.start(function(addr)
      if type(addr) == "number" then
        M.opts._mcp_url = "http://127.0.0.1:" .. addr .. "/mcp"
        M.opts._mcp_type = "http"
      else
        M.opts._mcp_url = addr
        M.opts._mcp_type = "unix"
      end
      local disp = (M.opts._mcp_type == "http") and M.opts._mcp_url or ("unix:" .. M.opts._mcp_url)
      vim.notify("[lazyagent] MCP server ready on " .. tostring(disp), vim.log.levels.INFO)
      write_mcp_configs(M.opts._mcp_url, M.opts)

      -- Register signal handlers that will stop the MCP server on SIGINT/SIGTERM
      register_signal_handlers(function() pcall(mcp_server.stop) end)
    end, start_opts)

    pcall(function()
      vim.api.nvim_create_autocmd("VimLeavePre", {
        group = vim.api.nvim_create_augroup("LazyAgentMCPCleanup", { clear = true }),
        callback = function()
          -- Stop server and remove any socket files
          pcall(function() mcp_server.stop() end)
          -- Close active sessions
          pcall(function() require("lazyagent.logic.session").close_all_sessions(true) end)
          -- Stop signal watchers if any
          pcall(function()
            if sig_int and type(sig_int.stop) == "function" then sig_int:stop() end
            if sig_term and type(sig_term.stop) == "function" then sig_term:stop() end
          end)
        end,
        desc = "Stop lazyagent MCP server on exit",
      })
    end)
  end
end

return M
