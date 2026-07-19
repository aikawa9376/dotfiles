local M = {}

local function module_root()
  local info = debug.getinfo(1, "S")
  local src = info and info.source
  if src and src:sub(1, 1) == "@" then
    src = src:sub(2)
  end
  return (src and src:match("(.*/lazyagent/)integrations/[^/]+%.lua$")) or ""
end

local function default_instructions_content()
  local paths = {
    module_root() .. "resources/default_instructions.md",
    vim.fn.stdpath("config") .. "/lua/plugins/lazyagent/lua/lazyagent/resources/default_instructions.md",
    vim.fn.stdpath("cache") .. "/lazyagent/default_instructions.md",
  }

  for _, md in ipairs(paths) do
    local file = io.open(md, "r")
    if file then
      local content = file:read("*a")
      file:close()
      if content and content ~= "" then
        return content
      end
    end
  end

  return ""
end

local function copy_hook_scripts(agent_dir)
  local src_dir = module_root() .. "resources/hooks"
  pcall(vim.fn.mkdir, agent_dir .. "/hooks", "p")

  for _, name in ipairs({ "notify-start.sh", "notify-done.sh", "open-file.sh" }) do
    local source = io.open(src_dir .. "/" .. name, "r")
    if source then
      local content = source:read("*a")
      source:close()

      local target_path = agent_dir .. "/hooks/" .. name
      local target = io.open(target_path, "w")
      if target then
        target:write(content)
        target:close()
      end
      os.execute("chmod +x " .. vim.fn.shellescape(target_path))
    end
  end
end

local function merge_json_files(paths)
  local merged = {}

  for _, path in ipairs(paths) do
    local file = io.open(path, "r")
    if file then
      local ok, parsed = pcall(vim.fn.json_decode, file:read("*a"))
      file:close()

      if ok and type(parsed) == "table" then
        for key, value in pairs(parsed) do
          if type(value) == "table" and type(merged[key]) == "table" then
            for nested_key, nested_value in pairs(value) do
              merged[key][nested_key] = nested_value
            end
          else
            merged[key] = value
          end
        end
      end
    end
  end

  return merged
end

local function write_json(path, value)
  local file = io.open(path, "w")
  if file then
    file:write(vim.fn.json_encode(value))
    file:close()
  end
end

local function write_file(path, value)
  local file = io.open(path, "w")
  if file then
    file:write(value)
    file:close()
  end
end

local function write_copilot_files(agent_dir, url, opts)
  local candidates = {}
  local copilot_config_dir = vim.fn.expand("$COPILOT_CONFIG_DIR")
  if copilot_config_dir and copilot_config_dir ~= "$COPILOT_CONFIG_DIR" and copilot_config_dir ~= "" then
    table.insert(candidates, copilot_config_dir .. "/mcp-config.json")
  end
  table.insert(candidates, vim.fn.expand("~/.config/.copilot/mcp-config.json"))
  table.insert(candidates, vim.fn.expand("~/.config/copilot/mcp-config.json"))
  table.insert(candidates, vim.fn.expand("~/.copilot/mcp-config.json"))

  local merged = merge_json_files(candidates)
  merged.mcpServers = merged.mcpServers or {}
  merged.mcpServers.lazyagent = {
    type = ((opts and opts._mcp_type) or "http"),
    url = (((opts and opts._mcp_type) == "unix") and ("unix:" .. url) or url),
  }

  write_json(agent_dir .. "/mcp-config.json", merged)
  write_file(agent_dir .. "/mcp.url", (opts and opts._mcp_url) or url)
  write_json(agent_dir .. "/plugin.json", {
    name = "lazyagent-hooks",
    description = "LazyAgent Neovim integration hooks",
    version = "0.0.1",
    hooks = "hooks.json",
  })
  copy_hook_scripts(agent_dir)
  write_json(agent_dir .. "/hooks.json", {
    version = 1,
    hooks = {
      userPromptSubmitted = { { type = "command", bash = "./hooks/notify-start.sh", timeoutSec = 10 } },
      agentStop = { { type = "command", bash = "./hooks/notify-done.sh", timeoutSec = 10 } },
      postToolUse = { { type = "command", bash = "./hooks/open-file.sh", timeoutSec = 10 } },
    },
  })
end

local function write_cursor_files(agent_dir, url, opts)
  local mcp_url = (opts and opts._mcp_url) or url
  write_file(agent_dir .. "/mcp.url", mcp_url)
  copy_hook_scripts(agent_dir)

  local cursor_cfg_path = vim.fn.expand("~/.cursor/mcp.json")
  local cursor_cfg = {}
  local cursor_cfg_file = io.open(cursor_cfg_path, "r")
  if cursor_cfg_file then
    local ok, parsed = pcall(vim.fn.json_decode, cursor_cfg_file:read("*a"))
    cursor_cfg_file:close()
    if ok and type(parsed) == "table" then
      cursor_cfg = parsed
    end
  end
  cursor_cfg.mcpServers = cursor_cfg.mcpServers or {}
  cursor_cfg.mcpServers.lazyagent = { url = mcp_url, type = "http" }
  write_json(cursor_cfg_path, cursor_cfg)

  local hooks_cfg_path = vim.fn.expand("~/.cursor/hooks.json")
  local hooks_cfg = {}
  local hooks_file = io.open(hooks_cfg_path, "r")
  if hooks_file then
    local ok, parsed = pcall(vim.fn.json_decode, hooks_file:read("*a"))
    hooks_file:close()
    if ok and type(parsed) == "table" then
      hooks_cfg = parsed
    end
  end

  hooks_cfg.version = 1
  hooks_cfg.hooks = hooks_cfg.hooks or {}
  hooks_cfg.hooks.beforeSubmitPrompt = hooks_cfg.hooks.beforeSubmitPrompt or {}
  table.insert(hooks_cfg.hooks.beforeSubmitPrompt, {
    command = agent_dir .. "/hooks/notify-start.sh",
    id = "lazyagent-notify-start",
  })
  hooks_cfg.hooks.afterFileEdit = hooks_cfg.hooks.afterFileEdit or {}
  table.insert(hooks_cfg.hooks.afterFileEdit, {
    command = agent_dir .. "/hooks/open-file.sh",
    id = "lazyagent-open-file",
  })
  hooks_cfg.hooks.stop = hooks_cfg.hooks.stop or {}
  table.insert(hooks_cfg.hooks.stop, {
    command = agent_dir .. "/hooks/notify-done.sh",
    id = "lazyagent-notify-done",
  })
  write_json(hooks_cfg_path, hooks_cfg)
end

local function write_mcp_configs(url, opts)
  local cache_dir = (opts and opts.cache and opts.cache.dir) or (vim.fn.stdpath("cache") .. "/lazyagent")
  vim.fn.mkdir(cache_dir, "p")

  local instructions = default_instructions_content()

  for name, _ in pairs((opts and opts.interactive_agents) or {}) do
    local lname = string.lower(name)
    local agent_dir = cache_dir .. "/agents/" .. lname
    pcall(vim.fn.mkdir, agent_dir, "p")

    if instructions ~= "" then
      write_file(agent_dir .. "/AGENTS.md", instructions)
    end

    if lname == "copilot" then
      write_copilot_files(agent_dir, url, opts)
    elseif lname == "gemini" then
      write_file(agent_dir .. "/mcp.url", (opts and opts._mcp_url) or url)
      copy_hook_scripts(agent_dir)
    elseif lname == "cursor" then
      write_cursor_files(agent_dir, url, opts)
    end
  end
end

local function cleanup_stale_resources(opts)
  local uv = vim.loop
  local cache_dir = (opts and opts.cache and opts.cache.dir) or (vim.fn.stdpath("cache") .. "/lazyagent")

  local runtime = os.getenv("XDG_RUNTIME_DIR") or vim.fn.stdpath("state")
  local sock_dir = runtime .. "/lazyagent"
  if vim.fn.isdirectory(sock_dir) == 1 then
    local ok, entries = pcall(vim.fn.readdir, sock_dir)
    if ok and type(entries) == "table" then
      for _, filename in ipairs(entries) do
        if filename:match("^lazyagent%-.*%.sock$") then
          local path = sock_dir .. "/" .. filename
          local stat = uv.fs_stat(path)
          if not stat or (os.time() - stat.mtime) > 24 * 3600 then
            pcall(function() uv.fs_unlink(path) end)
          end
        end
      end
    end
  end

  local persistence = require("lazyagent.logic.persistence")
  local backend_logic = require("lazyagent.logic.backend")
  local data = persistence.load()
  for key, pane_id in pairs(data) do
    local agent_name = key:match("^(.-)::.+$")
    if agent_name then
      local _, backend_mod = backend_logic.resolve_backend_for_agent(agent_name, nil)
      local exists = false
      if backend_mod and type(backend_mod.pane_exists) == "function" then
        local ok, result = pcall(backend_mod.pane_exists, pane_id)
        exists = ok and result == true
      end
      if not exists then
        persistence.remove_session(agent_name, key:match("^.-::(.+)$"))
      end
    end
  end

  local agents_dir = cache_dir .. "/agents"
  if vim.fn.isdirectory(agents_dir) == 1 then
    local ok, agent_dirs = pcall(vim.fn.readdir, agents_dir)
    if ok and type(agent_dirs) == "table" then
      for _, aname in ipairs(agent_dirs) do
        local apath = agents_dir .. "/" .. aname
        pcall(function() uv.fs_unlink(apath .. "/" .. string.upper(aname) .. ".md") end)
        pcall(function() uv.fs_unlink(apath .. "/lazyagent.mcp.json") end)
      end
    end
  end

  pcall(function() uv.fs_unlink(cache_dir .. "/lazyagent.mcp.json") end)
  pcall(function() uv.fs_unlink(cache_dir .. "/lazyagent-system-defaults.json") end)
end

local function allocate_port()
  local socket = vim.loop.new_tcp()
  local ok = pcall(function() socket:bind("127.0.0.1", 0) end)
  if not ok then
    pcall(function() socket:close() end)
    return nil
  end

  local addr = socket:getsockname()
  local port = addr and addr.port
  pcall(function() socket:close() end)
  return port
end

local function build_start_opts(opts)
  local start_opts = {}
  local ok_unix = vim.loop and vim.loop.os_uname and vim.loop.os_uname().sysname ~= "Windows_NT"

  if type(opts.mcp_fixed_port) == "number" then
    start_opts.port = opts.mcp_fixed_port
  elseif ok_unix then
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

  if start_opts.port then
    start_opts.sock_path = nil
  end
  if opts.mcp_host then
    start_opts.host = opts.mcp_host
  end

  return start_opts
end

function M.setup(opts)
  opts = opts or {}
  opts._mcp_url = nil
  opts._mcp_type = nil
end

function M.ensure_started(opts)
  opts = opts or {}
  if not opts.mcp_mode then
    return false
  end
  if opts._mcp_url or M._starting then
    return true
  end
  M._starting = true

  pcall(function() cleanup_stale_resources(opts) end)
  pcall(function() require("lazyagent.logic.cache").purge_old_conversations() end)

  local mcp_server = require("lazyagent.mcp.server")
  local sig_int
  local sig_term

  local function stop_signal_handlers()
    pcall(function()
      if sig_int and type(sig_int.stop) == "function" then sig_int:stop() end
      if sig_term and type(sig_term.stop) == "function" then sig_term:stop() end
    end)
  end

  local function register_signal_handlers()
    if not vim.loop.new_signal then
      return
    end
    sig_int = vim.loop.new_signal()
    sig_term = vim.loop.new_signal()
    sig_int:start("sigint", function() pcall(mcp_server.stop) end)
    sig_term:start("sigterm", function() pcall(mcp_server.stop) end)
  end

  mcp_server.start(function(addr)
    M._starting = false
    if type(addr) == "number" then
      opts._mcp_url = "http://127.0.0.1:" .. addr .. "/mcp"
      opts._mcp_type = "http"
    else
      opts._mcp_url = addr
      opts._mcp_type = "unix"
    end

    local display = (opts._mcp_type == "http") and opts._mcp_url or ("unix:" .. opts._mcp_url)
    vim.notify("[lazyagent] MCP server ready on " .. tostring(display), vim.log.levels.INFO)
    write_mcp_configs(opts._mcp_url, opts)
    register_signal_handlers()
  end, build_start_opts(opts))

  pcall(function()
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = vim.api.nvim_create_augroup("LazyAgentMCPCleanup", { clear = true }),
      callback = function()
        pcall(function() mcp_server.stop() end)
        M._starting = false
        pcall(function() require("lazyagent.logic.session").close_all_sessions(true) end)
        stop_signal_handlers()
      end,
      desc = "Stop lazyagent MCP server on exit",
    })
  end)
  return true
end

return M
