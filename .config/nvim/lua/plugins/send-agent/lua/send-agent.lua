local M = {}
-- Default keymap descriptors for the plugin (mode, lhs, rhs, opts).
function M.default_keymaps()
  local maps = {
    {
      mode = "v",
      lhs = "<leader>sa",
      rhs = function() M.send_visual() end,
      opts = { noremap = true, silent = true, desc = "Send Visual to Agent" },
    },
    {
      mode = "n",
      lhs = "<leader>sl",
      rhs = function() M.send_line() end,
      opts = { noremap = true, silent = true, desc = "Send Line to Agent" },
    },
  }

  -- Add agent-start shortcuts for configured interactive agents (if any).
  if M.opts and M.opts.interactive_agents then
    local agent_suffix_map = {
      Claude = "a",
      Codex = "x",
      Gemini = "g",
      Copilot = "c",
      Cursor = "r",
    }
    for name in pairs(M.opts.interactive_agents) do
      local suffix = agent_suffix_map[name] or string.sub(string.lower(name), 1, 1)
      table.insert(maps, {
        mode = "n",
        lhs = "<leader>sa" .. suffix,
        rhs = "<cmd>" .. name .. "<cr>",
        opts = { noremap = true, silent = true, desc = "Start " .. name .. " Agent" },
      })
    end
  end

  return maps
end

-- Register a list of keymap descriptors (or call default_keymaps() if none passed).
function M.register_keymaps(maps)
  maps = maps or M.default_keymaps()
  for _, m in ipairs(maps) do
    local mode = m.mode or "n"
    local rhs = m.rhs
    local lhs = m.lhs
    local opts = m.opts or {}
    -- Use pcall in case the rhs is a string (command) or a function; keymap.set handles both.
    pcall(function() vim.keymap.set(mode, lhs, rhs, opts) end)
  end
end

local tmux = require("send-agent.tmux")
local window = require("send-agent.window")
local util = require("send-agent.util")

-- Cache helpers for saving scratch buffer content per project branch and root.
-- Default cache directory is <stdpath("cache")>/send-agent
local function sanitize_filename_component(s)
  if not s then return "" end
  s = tostring(s)
  -- Replace path separators and whitespace with hyphens; keep alnum, underscore and dash.
  s = s:gsub("[^%w-_]+", "-")
  return s
end

local function git_root_for_path(path)
  path = path or vim.api.nvim_buf_get_name(0)
  if not path or path == "" then
    path = vim.fn.getcwd()
  end
  local cwd = vim.fn.fnamemodify(path, ":p:h")
  local cmd = "git -C " .. vim.fn.shellescape(cwd) .. " rev-parse --show-toplevel 2>/dev/null"
  local ok, out = pcall(vim.fn.systemlist, cmd)
  if ok and out and #out > 0 and out[1] and out[1] ~= "" then
    return out[1]
  end
  return nil
end

local function git_branch_for_path(path)
  path = path or vim.api.nvim_buf_get_name(0)
  if not path or path == "" then
    path = vim.fn.getcwd()
  end
  local cwd = vim.fn.fnamemodify(path, ":p:h")
  local cmd = "git -C " .. vim.fn.shellescape(cwd) .. " rev-parse --abbrev-ref HEAD 2>/dev/null"
  local ok, out = pcall(vim.fn.systemlist, cmd)
  if ok and out and #out > 0 and out[1] and out[1] ~= "" then
    return out[1]
  end
  return nil
end

local function get_cache_dir()
  local dir = (M.opts and M.opts.cache and M.opts.cache.dir) or (vim.fn.stdpath("cache") .. "/send-agent")
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
  return dir
end

local function build_cache_filename(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local bufn = vim.api.nvim_buf_get_name(bufnr) or ""
  local root = git_root_for_path(bufn) or vim.fn.getcwd()
  local rootname = vim.fn.fnamemodify(root, ":t") or "root"
  local branch = git_branch_for_path(bufn) or "no-branch"
  local date = os.date("%Y-%m-%d")
  return sanitize_filename_component(branch) .. "-" .. sanitize_filename_component(rootname) .. "-" .. date .. ".log"
end

local function write_scratch_to_cache(bufnr)
  if not (M.opts and M.opts.cache and M.opts.cache.enabled) then
    return
  end
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local dir = get_cache_dir()
  local filename = build_cache_filename(bufnr)
  local path = dir .. "/" .. filename

  local content = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false) or {}
  local ts = os.date("%Y-%m-%d %H:%M:%S")
  local header = { string.format("===== scratch saved at %s =====", ts), "" }
  local to_write = {}
  for _, h in ipairs(header) do table.insert(to_write, h) end
  for _, l in ipairs(content) do table.insert(to_write, l) end
  table.insert(to_write, "") -- newline
  pcall(vim.fn.writefile, to_write, path, "a")
end

local function attach_cache_autocmds(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  if not (M.opts and M.opts.cache and M.opts.cache.enabled) then return end
  local gid = vim.api.nvim_create_augroup("SendAgentScratchCache-" .. tostring(bufnr), { clear = true })
  local debounce_ms = (M.opts.cache and M.opts.cache.debounce_ms) or 1000
  local scheduled = false
  local function schedule_write()
    if scheduled then return end
    scheduled = true
    vim.defer_fn(function()
      scheduled = false
      write_scratch_to_cache(bufnr)
    end, debounce_ms)
  end

  vim.api.nvim_create_autocmd({ "BufWritePost", "BufLeave", "InsertLeave", "TextChanged" }, {
    group = gid,
    buffer = bufnr,
    callback = function() schedule_write() end,
  })
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = gid,
    buffer = bufnr,
    callback = function()
      write_scratch_to_cache(bufnr)
      pcall(vim.api.nvim_del_augroup_by_id, gid)
    end,
  })
end

M.attach_cache_to_buf = attach_cache_autocmds

-- Sessions table for reuse / tracking of tmux panes per agent
M.sessions = {}
M.open_agent = nil

local resolve_target_agent

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
    interactive_agents = {
      Claude = {
        cmd = "claude",
        pane_size = 30,
        scratch_filetype = "markdown",
        submit_keys = { "C-m" },
        submit_delay = 600,
        submit_retry = 1,
      },
      Codex = {
        cmd = "codex",
        pane_size = 40,
        scratch_filetype = "markdown",
        submit_keys = { "C-m" },
        submit_delay = 600,
        submit_retry = 1,
      },
      Gemini = {
        cmd = "gemini",
        pane_size = 30,
        scratch_filetype = "markdown",
        submit_keys = { "C-m" },
        submit_delay = 600,
        submit_retry = 1,
      },
      Copilot = {
        cmd = "copilot",
        pane_size = 30,
        scratch_filetype = "markdown",
        submit_keys = { "C-m" },
        submit_delay = 600,
        submit_retry = 1,
      },
      Cursor = {
        cmd = "cursor-agent",
        pane_size = 30,
        scratch_filetype = "markdown",
        submit_keys = { "C-m" },
        submit_delay = 600,
        submit_retry = 1,
      },
    },
    window_type = "float",
    -- Default delay (ms) to wait after paste before sending submit keys; and retry count
    submit_delay = 600,
    submit_retry = 1,
    debug = false,
    -- Controls whether the floating input buffer is closed after a submit.
    close_on_send = true,
    -- Default send keys (insert and normal mode). Users can override in setup opts.
    send_key_insert = "<C-CR>",
    send_key_normal = "<CR>",
    -- Whether we register default keymaps automatically. Prefer central mapping in init.lua.
    setup_keymaps = false,
    -- Buffer-local scratch keymaps (can be overridden per agent or by opts).
    -- Supported keys:
    --   close          - normal mode: close buffer
    --   send_and_clear - normal/insert: send and clear buffer
    --   scroll_up/down - normal: scroll agent pane output
    --   nav_up/down    - normal/insert: send Up/Down to agent pane
    scratch_keymaps = {
      close = "q",
      send_and_clear = "<C-Space>",
      scroll_up = "<C-u>",
      scroll_down = "<C-d>",
      nav_up = "<Up>",
      nav_down = "<Down>",
    },
    cache = { enabled = true, dir = vim.fn.stdpath("cache") .. "/send-agent", debounce_ms = 1500 },
    send_number_keys_to_agent = true,
  }

  M.opts = vim.tbl_deep_extend("force", default_opts, opts or {})

  if M._configured then
    return
  end
  M._configured = true

  -- Helper to create commands safely
  local function try_create_user_command(name, fn, opts)
    pcall(function() vim.api.nvim_create_user_command(name, fn, opts) end)
  end

  -- Register convenience scratch starter command
  try_create_user_command("SendAgentScratch", function(cmdargs)
    local explicit = (cmdargs and cmdargs.args and cmdargs.args ~= "") and cmdargs.args or nil
    resolve_target_agent(explicit, nil, function(chosen)
      if not chosen then return end
      M.start_interactive_session({ agent_name = chosen, reuse = true })
    end)
  end, { nargs = "?", desc = "Open a scratch buffer for sending instructions to AI agent" })

  try_create_user_command("SendAgentClose", function(cmdargs)
    local explicit = (cmdargs and cmdargs.args and cmdargs.args ~= "") and cmdargs.args or nil
    resolve_target_agent(explicit, nil, function(chosen)
      if not chosen then return end
      M.close_session(chosen)
    end)
  end, { nargs = "?", desc = "Close an agent tmux pane by name (optional agent name)" })

  try_create_user_command("SendAgentToggle", function(cmdargs)
    local explicit = (cmdargs and cmdargs.args and cmdargs.args ~= "") and cmdargs.args or nil
    resolve_target_agent(explicit, nil, function(chosen)
      if not chosen then return end
      M.toggle_session(chosen)
    end)
  end, { nargs = "?", desc = "Toggle the floating agent input buffer (open/close)" })

  -- Register commands for each interactive agent
  if M.opts.interactive_agents then
    for name, agent_opts in pairs(M.opts.interactive_agents) do
      try_create_user_command(name, function(cmdargs)
        local explicit = (cmdargs and cmdargs.args and cmdargs.args ~= "") and cmdargs.args or nil
        if explicit then
          M.start_interactive_session({
            agent_name = explicit,
            reuse = true,
            pane_size = agent_opts.pane_size,
            scratch_filetype = agent_opts.scratch_filetype,
          })
          return
        end

        -- No explicit agent passed; use selection rules:
        resolve_target_agent(nil, name, function(chosen)
          if not chosen then return end
          M.start_interactive_session({
            agent_name = chosen,
            reuse = true,
            pane_size = agent_opts.pane_size,
            scratch_filetype = agent_opts.scratch_filetype,
          })
        end)
      end, {
          nargs = "?",
          desc = "Start interactive agent: " .. name,
        })
    end
  end

  -- If enabled, register default keymaps after all options are available.
  if M.opts.setup_keymaps then
    M.register_keymaps()
  end

  -- Close all agent sessions on Quit/Exit
  pcall(function()
    local group = vim.api.nvim_create_augroup("SendAgentCleanup", { clear = true })
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = group,
      callback = function()
        M.close_all_sessions()
      end,
      desc = "Close send-agent tmux sessions on exit",
    })
  end)
end

local function get_interactive_agent(agent)
  return M.opts.interactive_agents and M.opts.interactive_agents[agent] or nil
end

-- Get names of agents that appear to have active tmux panes (live sessions).
local function get_active_agents()
  local active = {}
  for name, s in pairs(M.sessions or {}) do
    if s and s.pane_id and s.pane_id ~= "" then
      if tmux and type(tmux.pane_exists) == "function" then
        if tmux.pane_exists(s.pane_id) then table.insert(active, name) end
      else
        -- If tmux.pane_exists isn't available, consider session table as the source of truth.
        table.insert(active, name)
      end
    end
  end
  return active
end

-- Resolve the target agent to use:
-- 1) If 'explicit' is provided, use it.
-- 2) If exactly one active agent is present, use it.
-- 3) If multiple active agents are present, present a ui.select of the active agents.
-- 4) If no active agents exist: if 'hint' is provided and valid, use it; otherwise, present ui.select of configured agents.
resolve_target_agent = function(explicit, hint, callback)
  callback = callback or function() end

  if explicit and explicit ~= "" then
    callback(explicit)
    return
  end

  local active = get_active_agents()
  if #active == 1 then
    callback(active[1])
    return
  end

  if #active > 1 then
    vim.ui.select(active, { prompt = "Choose running agent:" }, function(choice)
      if choice and choice ~= "" then callback(choice) end
    end)
    return
  end

  -- No active agents
  local available = {}
  for k, _ in pairs(M.opts.interactive_agents or {}) do table.insert(available, k) end

  -- If a hint (e.g. command name) is provided and valid, use it directly.
  if hint and hint ~= "" and M.opts.interactive_agents and M.opts.interactive_agents[hint] then
    callback(hint)
    return
  end

  if #available == 0 then
    callback(nil)
    return
  end

  if #available == 1 then
    callback(available[1])
    return
  end

  vim.ui.select(available, { prompt = "Choose agent to start:" }, function(choice)
    if choice and choice ~= "" then callback(choice) end
  end)
end

-- Export small helpers so other parts or user code can query/use them.
M.get_active_agents = get_active_agents
M.resolve_target_agent = resolve_target_agent

local function ensure_session(agent_name, agent_cfg, reuse, on_ready)
  if reuse and M.sessions[agent_name] and M.sessions[agent_name].pane_id and M.sessions[agent_name].pane_id ~= "" and tmux.pane_exists(M.sessions[agent_name].pane_id) then
    on_ready(M.sessions[agent_name].pane_id)
    return
  end

  tmux.split(agent_cfg.cmd, agent_cfg.pane_size or 30, agent_cfg.is_vertical or false, function(pane_id)
    if not pane_id or pane_id == "" then
      vim.notify("Failed to create tmux pane for agent " .. tostring(agent_name), vim.log.levels.ERROR)
      return
    end
    M.sessions[agent_name] = { pane_id = pane_id, last_output = "" }
    on_ready(pane_id)
  end)
end

-- Register buffer-local keymaps used for scratch buffers.
-- bufnr: buffer number
-- opts: {
--   agent_name: optional string,
--   agent_cfg: optional table,
--   pane_id: optional string,
--   reuse: optional bool,
--   scratch_keymaps: optional overrides
-- }
function M.register_scratch_keymaps(bufnr, opts)
  opts = opts or {}
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end

  local agent_name = opts.agent_name
  local agent_cfg = opts.agent_cfg or (agent_name and get_interactive_agent(agent_name) or nil)
  local pane_id = opts.pane_id
  local reuse = opts.reuse ~= false

  -- Merge keymap settings: defaults -> agent-specific -> per-call overrides
  local keys = {}
  keys = vim.tbl_deep_extend("force", keys, (M.opts and M.opts.scratch_keymaps) or {})
  if agent_cfg and agent_cfg.scratch_keymaps then
    keys = vim.tbl_deep_extend("force", keys, agent_cfg.scratch_keymaps)
  end
  if opts.scratch_keymaps then
    keys = vim.tbl_deep_extend("force", keys, opts.scratch_keymaps)
  end

  local function safe_set(mode, lhs, rhs, mapopts)
    local map_opt = vim.tbl_deep_extend("force", { buffer = bufnr, noremap = true, silent = true }, mapopts or {})
    pcall(function() vim.keymap.set(mode, lhs, rhs, map_opt) end)
  end

  local function send_from_buf(close_after)
    local pane = pane_id or (agent_name and M.sessions[agent_name] and M.sessions[agent_name].pane_id) or nil
    if not pane or pane == "" then
      -- fallback to generic prompt API
      M.send_buffer_and_clear(agent_name, bufnr)
      return
    end
    local content = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local text = table.concat(content, "\n")
    if text and #text > 0 then
      local submit_keys = (agent_cfg and agent_cfg.submit_keys) or ((agent_name and get_interactive_agent(agent_name) and get_interactive_agent(agent_name).submit_keys) or nil)
      local submit_delay = (agent_cfg and agent_cfg.submit_delay) or (M.opts and M.opts.submit_delay) or 600
      local submit_retry = (agent_cfg and agent_cfg.submit_retry) or (M.opts and M.opts.submit_retry) or 1
      tmux.paste_and_submit(pane, text, submit_keys, {
        submit_delay = submit_delay,
        submit_retry = submit_retry,
        debug = M.opts.debug,
      })
      pcall(function() vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {}) end)
      if close_after or M.opts.close_on_send then
        window.close()
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
          vim.api.nvim_buf_delete(bufnr, { force = true })
        end
        M.open_agent = nil
        if agent_name and M.sessions[agent_name] and M.sessions[agent_name].pane_id and not reuse then
          tmux.kill_pane(M.sessions[agent_name].pane_id)
          M.sessions[agent_name] = nil
        end
      end
    end
  end

  -- Close mapping
  safe_set("n", keys.close or "q", function()
    window.close()
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true, nowait = true })
    end
    M.open_agent = nil
    if agent_name and M.sessions[agent_name] and M.sessions[agent_name].pane_id and not reuse then
      tmux.kill_pane(M.sessions[agent_name].pane_id)
      M.sessions[agent_name] = nil
    end
  end, { desc = "Close input buffer" })

  -- Submit mappings (normal / insert)
  safe_set("n", M.opts.send_key_normal or "<CR>", function() send_from_buf() end, { desc = "Submit from buffer" })
  safe_set("i", M.opts.send_key_insert or "<C-CR>", function()
    vim.cmd("stopinsert")
    send_from_buf()
    if vim.api.nvim_buf_is_valid(bufnr) then vim.cmd("startinsert") end
  end, { desc = "Submit from insert mode" })

  -- Send & clear (scratch)
  safe_set("n", keys.send_and_clear or "<C-Space>", function() M.send_buffer_and_clear(agent_name, bufnr) end, { desc = "Send buffer and clear (scratch)" })
  safe_set("i", keys.send_and_clear or "<C-Space>", function()
    vim.cmd("stopinsert")
    M.send_buffer_and_clear(agent_name, bufnr)
    if vim.api.nvim_buf_is_valid(bufnr) then vim.cmd("startinsert") end
  end, { desc = "Send buffer and clear (insert mode)" })

  -- Scroll mappings
  safe_set("n", keys.scroll_up or "<C-u>", function()
    local pane = pane_id or (agent_name and M.sessions[agent_name] and M.sessions[agent_name].pane_id)
    if pane then tmux.scroll_up(pane) end
  end, { desc = "Scroll agent pane up" })
  safe_set("n", keys.scroll_down or "<C-d>", function()
    local pane = pane_id or (agent_name and M.sessions[agent_name] and M.sessions[agent_name].pane_id)
    if pane then tmux.scroll_down(pane) end
  end, { desc = "Scroll agent pane down" })

  -- Navigation keys
  safe_set("n", keys.nav_up or "<Up>", function()
    local pane = pane_id or (agent_name and M.sessions[agent_name] and M.sessions[agent_name].pane_id)
    if pane then tmux.send_keys(pane, { "Up" }) end
  end, { desc = "Send Up to agent pane" })
  safe_set("n", keys.nav_down or "<Down>", function()
    local pane = pane_id or (agent_name and M.sessions[agent_name] and M.sessions[agent_name].pane_id)
    if pane then tmux.send_keys(pane, { "Down" }) end
  end, { desc = "Send Down to agent pane" })

  safe_set("i", keys.nav_up or "<Up>", function()
    vim.cmd("stopinsert")
    local pane = pane_id or (agent_name and M.sessions[agent_name] and M.sessions[agent_name].pane_id)
    if pane then tmux.send_keys(pane, { "Up" }) end
    if vim.api.nvim_buf_is_valid(bufnr) then vim.cmd("startinsert") end
  end, { desc = "Send Up to agent pane (insert mode)" })
  safe_set("i", keys.nav_down or "<Down>", function()
    vim.cmd("stopinsert")
    local pane = pane_id or (agent_name and M.sessions[agent_name] and M.sessions[agent_name].pane_id)
    if pane then tmux.send_keys(pane, { "Down" }) end
    if vim.api.nvim_buf_is_valid(bufnr) then vim.cmd("startinsert") end
  end, { desc = "Send Down to agent pane (insert mode)" })

  if M.opts.send_number_keys_to_agent then
    local function send_number_to_agent(number)
      if M.open_agent and M.sessions[M.open_agent] and M.sessions[M.open_agent].pane_id then
        if tmux.pane_exists(M.sessions[M.open_agent].pane_id) then
          agent_name = M.open_agent
          pane_id = M.sessions[agent_name].pane_id
        end
      end

      if not agent_name then
        local active_agents = get_active_agents()
        if #active_agents == 1 then
          agent_name = active_agents[1]
          pane_id = M.sessions[agent_name].pane_id
        end
      end

      if pane_id then
        tmux.send_keys(pane_id, { tostring(number) })
      else
        -- Fallback to default Neovim behavior if no unambiguous agent is found.
        vim.api.nvim_feedkeys(tostring(number), "n", false)
      end
    end

    local function create_keymap_func(number)
      return function()
        send_number_to_agent(number)
      end
    end

    for i = 0, 9 do
      safe_set("n", tostring(i),
        create_keymap_func(i)
      , { desc = "Send " .. i .. " to agent" })
    end
  end

end

-- Helper to send text to a pane and optionally kill it after a delay.
-- Used for one-shot commands.
local function send_and_close_if_needed(agent_name, pane_id, text, agent_cfg, reuse)
  if not text or text == "" then
    return
  end

  tmux.paste_and_submit(pane_id, text, agent_cfg.submit_keys, {
    submit_delay = agent_cfg.submit_delay or M.opts.submit_delay,
    submit_retry = agent_cfg.submit_retry or M.opts.submit_retry,

    debug = M.opts.debug,
  })

  -- For one-shot (non-interactive) sends, kill the pane after a delay if it's not meant to be reused.
  vim.defer_fn(function()
    if not reuse then
      tmux.kill_pane(pane_id)
      M.sessions[agent_name] = nil
    end
  end, agent_cfg.capture_delay or 800)
end

function M.close_session(agent_name)
  if not agent_name or agent_name == "" then
    return
  end
  if M.sessions[agent_name] and M.sessions[agent_name].pane_id and M.sessions[agent_name].pane_id ~= "" then
    tmux.kill_pane(M.sessions[agent_name].pane_id)
  end
  M.sessions[agent_name] = nil
end

-- Kill all known tmux sessions and clear local state.
function M.close_all_sessions()
  for name, s in pairs(M.sessions) do
    if s and s.pane_id and s.pane_id ~= "" then
      tmux.kill_pane(s.pane_id)
    end
    M.sessions[name] = nil
  end
end

-- Toggle the floating input for the named agent. If it is open, close it;
-- otherwise start (or reuse) an interactive session. This will not kill the
-- tmux pane unless the session was started without reuse.
function M.toggle_session(agent_name)
  local function _toggle(chosen)
    if not chosen or chosen == "" then return end

    local initial_input = nil
    local current_mode = vim.fn.mode()
    if current_mode:match("[vV\\x16]") then
      local text = util.get_visual_selection()
      -- If selection was lost, try to reselect with 'gv' and fetch again
      if not text or #text == 0 then
        vim.cmd("silent! normal! gv")
        text = util.get_visual_selection()
      end

      if text and #text > 0 then
        local start_pos = vim.fn.getpos("'<")
        local end_pos = vim.fn.getpos("'>")
        local start_line = start_pos[2]
        local end_line = end_pos[2]
        local file_path = vim.api.nvim_buf_get_name(0)
        if file_path and file_path ~= "" then
          file_path = vim.fn.fnamemodify(file_path, ":.")
        end

        local location_str = ""
        if file_path and file_path ~= "" and start_line > 0 and end_line > 0 then
          if start_line == end_line then
            location_str = string.format("@%s:%d", file_path, start_line)
          else
            location_str = string.format("@%s:%d-%d", file_path, start_line, end_line)
          end
        end

        if location_str ~= "" then
          initial_input = location_str
        end
      end

      -- Exit visual mode
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
    end

    -- If the floating input is already open for this agent, close it.
    if M.open_agent == chosen and window.is_open() then
      local bufnr = window.get_bufnr()
      window.close()
      if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
      M.open_agent = nil
      -- if there is no input to show, just close and exit
      if not initial_input then
        return
      end
    end

    -- Otherwise, start an interactive session (reuse = true by default).
    M.start_interactive_session({ agent_name = chosen, reuse = true, initial_input = initial_input })
  end

  resolve_target_agent(agent_name, nil, _toggle)
end

-- Starts an interactive session (tmux pane + scratch in/out) for the named agent.
-- opts.agent_name (string) required; opts.reuse (bool) optional; opts.initial_input optional
function M.start_interactive_session(opts)
  opts = opts or {}
  local agent_name = opts.agent_name or opts.name
  if not agent_name or agent_name == "" then
    -- If caller didn't provide an explicit agent name, use resolve_target_agent to select one.
    local hint = opts.name or opts.agent_hint or nil
    resolve_target_agent(nil, hint, function(chosen)
      if not chosen or chosen == "" then return end
      opts.agent_name = chosen
      M.start_interactive_session(opts)
    end)
    return
  end

  local agent_cfg = get_interactive_agent(agent_name)
  if not agent_cfg then
    vim.notify("interactive agent " .. tostring(agent_name) .. " is not configured", vim.log.levels.ERROR)
    return
  end

  -- Default to reuse sessions unless explicitly disabled
  local reuse = opts.reuse ~= false
  ensure_session(agent_name, agent_cfg, reuse, function(pane_id)
    -- Handle one-shot sends where no input scratch buffer is opened.
    if opts.open_input == false then
      send_and_close_if_needed(agent_name, pane_id, opts.initial_input, agent_cfg, reuse)
      return
    end

    -- Create an input buffer and open it in a floating window.
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].bufhidden = "wipe"
    vim.bo[bufnr].modifiable = true
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].filetype = agent_cfg.scratch_filetype or "markdown"
    -- Attach cache auto-save to this buffer (if enabled).
    pcall(function()
      if M.attach_cache_to_buf then M.attach_cache_to_buf(bufnr) end
    end)



    -- Register buffer-local scratch keymaps
    M.register_scratch_keymaps(bufnr, { agent_name = agent_name, agent_cfg = agent_cfg, pane_id = pane_id, reuse = reuse })

    M.open_agent = agent_name
    window.open(bufnr, { window_type = M.opts.window_type })

    -- Set initial content if provided
    if opts.initial_input and opts.initial_input ~= "" then
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(opts.initial_input, "\n"))
    end

    -- Send an initial input if provided.
    if opts.initial_input and opts.initial_input ~= "" then
      tmux.paste_and_submit(pane_id, opts.initial_input, agent_cfg.submit_keys, {
        submit_delay = agent_cfg.submit_delay or M.opts.submit_delay,
        submit_retry = agent_cfg.submit_retry or M.opts.submit_retry,
        debug = M.opts.debug,
      })
    end
  end)
end

-- Send direct one-shot text to the interactive agent (creates or reuses a tmux pane, sends, and may keep it).
-- Default to reuse existing sessions for better UX (previously false).
function M.send_to_cli(agent_name, text)
  if not agent_name or agent_name == "" then
    resolve_target_agent(nil, nil, function(chosen)
      if not chosen then return end
      M.start_interactive_session({ agent_name = chosen, initial_input = text, reuse = true, open_input = false })
    end)
    return
  end
  M.start_interactive_session({ agent_name = agent_name, initial_input = text, reuse = true, open_input = false })
end

-- Send the contents of a buffer to the specified agent and clear the buffer.
-- This function does NOT close the scratch window; it only clears buffer contents.
-- agent_name: optional string - agent name (Gemini / Claude / etc). If not specified,
--             uses M.open_agent if available, or falls back to filetype mapping.
-- bufnr: optional number - buffer to send (defaults to current buffer).
function M.send_buffer_and_clear(agent_name, bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    vim.notify("send_buffer_and_clear: invalid buffer", vim.log.levels.ERROR)
    return
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local text = table.concat(lines, "\n")
  if not text or #text == 0 then
    vim.notify("send_buffer_and_clear: buffer is empty", vim.log.levels.INFO)
    return
  end

  -- determine agent_name if not specified
  if not agent_name or agent_name == "" then
    if M.open_agent and M.open_agent ~= "" then
      agent_name = M.open_agent
    else
      local ft = vim.api.nvim_buf_get_option(bufnr, "filetype")
      local settings = (M.opts and M.opts.filetype_settings) and (M.opts.filetype_settings[ft] or M.opts.filetype_settings["*"]) or nil
      if settings and settings.agent then
        agent_name = settings.agent
      end
    end
  end

  -- If agent still isn't determined, prompt the user to pick one.
  if not agent_name or agent_name == "" then
    resolve_target_agent(nil, nil, function(chosen)
      if not chosen or chosen == "" then
        vim.notify("send_buffer_and_clear: no agent available for sending", vim.log.levels.ERROR)
        return
      end
      M.send_buffer_and_clear(chosen, bufnr)
    end)
    return
  end

  local agent_cfg = get_interactive_agent(agent_name)
  if agent_cfg then
    -- For interactive agents (tmux-based), ensure a pane then paste/submit.
    ensure_session(agent_name, agent_cfg, true, function(pane_id)
      if not pane_id or pane_id == "" then
        vim.notify("send_buffer_and_clear: failed to obtain pane for " .. tostring(agent_name), vim.log.levels.ERROR)
        return
      end
      tmux.paste_and_submit(pane_id, text, agent_cfg.submit_keys, {
        submit_delay = agent_cfg.submit_delay or M.opts.submit_delay,
        submit_retry = agent_cfg.submit_retry or M.opts.submit_retry,

        debug = M.opts.debug,
      })
      pcall(function() vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {}) end)
    end)
    return
  end

  -- Not interactive: if there's a prompt handler, call it and clear the buffer afterwards.
  local p = M.opts and M.opts.prompts and M.opts.prompts[agent_name] or nil
  if p then
    local filename = vim.api.nvim_buf_get_name(bufnr) or ""
    local ft = vim.api.nvim_buf_get_option(bufnr, "filetype") or ""
    local context = { filename = filename, text = text, filetype = ft, selection = text }
    p(context)
    pcall(function() vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {}) end)
    return
  end

  vim.notify("send_buffer_and_clear: agent " .. tostring(agent_name) .. " is not configured", vim.log.levels.ERROR)
end

-- Convenience wrapper to send and clear the current buffer.
function M.send_and_clear(agent_name)
  M.send_buffer_and_clear(agent_name, vim.api.nvim_get_current_buf())
end

function M.send(text)
  if not text or #text == 0 then
    vim.notify("text is empty", vim.log.levels.ERROR)
    return
  end

  local ft = vim.bo.filetype
  local settings = M.opts.filetype_settings[ft] or M.opts.filetype_settings["*"]
  if not settings then
    vim.notify("filetype " .. ft .. " is not supported", vim.log.levels.ERROR)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local filename = vim.api.nvim_buf_get_name(bufnr)
  if filename == "" then
    filename = "untitled." .. ft
  end

  local context = {
    filename = filename,
    text = text,
    filetype = ft,
    selection = text,
  }

  local agent = settings.agent
  -- If agent exists as an interactive (tmux/CLI) agent, send via the CLI integration
  if get_interactive_agent(agent) then
    M.send_to_cli(agent, text)
    return
  end

  -- fallback: "gen" prompt expects user to input prompt text
  if agent == "gen" then
    vim.ui.input({ prompt = "Enter prompt: " }, function(input)
      if input and #input > 0 then
        context.prompt = input
        local p = M.opts.prompts and M.opts.prompts["gen"]
        if p then
          p(context)
        else
          vim.notify("gen prompt is not defined", vim.log.levels.ERROR)
        end
      end
    end)
  else
    -- regular prompts table
    local p = M.opts.prompts and M.opts.prompts[agent]
    if p then
      p(context)
    else
      vim.notify("prompt for agent " .. agent .. " is not defined", vim.log.levels.ERROR)
    end
  end
end

function M.send_visual()
  local text = util.get_visual_selection()
  -- If selection was lost, try to reselect with 'gv' and fetch again
  if not text or #text == 0 then
    vim.cmd("silent! normal! gv")
    text = util.get_visual_selection()
  end
  M.send(text)
end

function M.send_line()
  local text = vim.api.nvim_get_current_line()
  M.send(text)
end

return M
