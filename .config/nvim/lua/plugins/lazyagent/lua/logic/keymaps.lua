-- logic/keymaps.lua
-- This module handles the registration of keymaps, both global and buffer-local
-- for scratch buffers.
local M = {}

local state = require("logic.state")
local agent_logic = require("logic.agent")
local backend_logic = require("logic.backend")
local send_logic = require("logic.send")
local window = require("lazyagent.window")

---
-- Defines default keymap descriptors for the plugin.
-- @return (table) A list of keymap descriptors.
function M.default_keymaps()
  local maps = {
    {
      mode = "v",
      lhs = "<leader>sa",
      rhs = function() send_logic.send_visual() end,
      opts = { noremap = true, silent = true, desc = "Send Visual to Agent" },
    },
    {
      mode = "n",
      lhs = "<leader>sl",
      rhs = function() send_logic.send_line() end,
      opts = { noremap = true, silent = true, desc = "Send Line to Agent" },
    },
  }

  -- Add agent-start shortcuts for configured interactive agents (if any).
  if state.opts and state.opts.interactive_agents then
    local agent_suffix_map = {
      Claude = "a",
      Codex = "x",
      Gemini = "g",
      Copilot = "c",
      Cursor = "r",
    }
    for name in pairs(state.opts.interactive_agents) do
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

---
-- Registers a list of keymap descriptors.
-- If no maps are provided, default_keymaps() will be called.
-- @param maps (table|nil) A list of keymap descriptors.
function M.register_keymaps(maps)
  maps = maps or M.default_keymaps()
  for _, m in ipairs(maps) do
    local mode = m.mode or "n"
    local rhs = m.rhs
    local lhs = m.lhs
    local opts = m.opts or {}
    -- Use pcall in case the rhs is a string (command) or a function; vim.keymap.set handles both.
    pcall(function() vim.keymap.set(mode, lhs, rhs, opts) end)
  end
end

---
-- Registers buffer-local keymaps used for scratch buffers.
-- @param bufnr (number) The buffer number to register keymaps for.
-- @param opts (table) Options for keymap registration, including:
--   - agent_name (string): The name of the agent.
--   - agent_cfg (table): The agent's configuration.
--   - pane_id (string): The ID of the associated pane.
--   - reuse (boolean): Whether the pane is reused.
--   - source_bufnr (number): The original buffer that triggered the scratch.
--   - scratch_keymaps (table): Overrides for default scratch keymaps.
function M.register_scratch_keymaps(bufnr, opts)
  opts = opts or {}
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end

  local source_bufnr = opts.source_bufnr or opts.origin_bufnr or vim.api.nvim_get_current_buf()
  if source_bufnr and source_bufnr > 0 then
    pcall(function() vim.b[bufnr].lazyagent_source_bufnr = source_bufnr end)
  end

  local agent_name = opts.agent_name
  local agent_cfg = opts.agent_cfg or (agent_name and agent_logic.get_interactive_agent(agent_name) or nil)
  local pane_id = opts.pane_id
  local reuse = opts.reuse ~= false

  local _, backend_mod = backend_logic.resolve_backend_for_agent(agent_name, agent_cfg)

  -- Merge keymap settings: defaults -> agent-specific -> per-call overrides
  local keys = {}
  keys = vim.tbl_deep_extend("force", keys, (state.opts and state.opts.scratch_keymaps) or {})
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

  local function get_pane()
    return pane_id or (agent_name and state.sessions[agent_name] and state.sessions[agent_name].pane_id) or nil
  end

  local function send_key_to_pane(key, insert_wrap)
    local p = get_pane()
    if not p then return end
    if insert_wrap and vim.fn.mode():sub(1,1) == "i" then
      vim.cmd("stopinsert")
    end
    backend_mod.send_keys(p, { key })
    if insert_wrap and vim.api.nvim_buf_is_valid(bufnr) then
      vim.cmd("startinsert")
    end
  end

    local function send_from_buf(close_after)
      local pane = pane_id or (agent_name and state.sessions[agent_name] and state.sessions[agent_name].pane_id) or nil
      if not pane or pane == "" then
        -- fallback to generic prompt API
        send_logic.send_buffer_and_clear(agent_name, bufnr)
        return
      end
      local content = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local text = table.concat(content, "\n")
      -- Expand placeholders before sending (use source_bufnr information)
      local transforms = require("lazyagent.transforms") -- require here to avoid circular dependency
      local expanded_text, _ = transforms.expand(text, { source_bufnr = source_bufnr, scratch_bufnr = bufnr })
      text = expanded_text or text

      if text and #text > 0 then
        local cache_logic = require("logic.cache") -- require here to avoid circular dependency
        local submit_keys = (agent_cfg and agent_cfg.submit_keys) or ((agent_name and agent_logic.get_interactive_agent(agent_name) and agent_logic.get_interactive_agent(agent_name).submit_keys) or nil)
        local submit_delay = (agent_cfg and agent_cfg.submit_delay) or (state.opts and state.opts.submit_delay) or 600
        local submit_retry = (agent_cfg and agent_cfg.submit_retry) or (state.opts and state.opts.submit_retry) or 1
        -- Save scratch content to cache on send
        cache_logic.write_scratch_to_cache(bufnr)
        backend_mod.paste_and_submit(pane, text, submit_keys, {
          submit_delay = submit_delay,
          submit_retry = submit_retry,
          debug = state.opts.debug,
        })
        pcall(function() vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {}) end)
        if close_after or state.opts.close_on_send then
          window.close()
          if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
          end
          state.open_agent = nil
          if agent_name and state.sessions[agent_name] and state.sessions[agent_name].pane_id and not reuse then
            local session_logic = require("logic.session") -- require here to avoid circular dependency
            session_logic.close_session(agent_name)
          end
        end
      end
    end

  -- Close mapping
  safe_set("n", keys.close or "q", function()
    window.close()
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
    state.open_agent = nil
    if agent_name and state.sessions[agent_name] and state.sessions[agent_name].pane_id and not reuse then
      local session_logic = require("logic.session") -- require here to avoid circular dependency
      session_logic.close_session(agent_name)
    end
  end, { nowait = true, desc = "Close input buffer"  })

  -- Submit mappings (normal / insert)
  safe_set("n", state.opts.send_key_normal or "<CR>", function() send_from_buf() end, { desc = "Submit from buffer" })
  safe_set("i", state.opts.send_key_insert or "<C-s>", function()
    vim.cmd("stopinsert")
    send_from_buf()
    if vim.api.nvim_buf_is_valid(bufnr) then vim.cmd("startinsert") end
  end, { desc = "Submit from insert mode" })

  -- Send & clear (scratch)
  safe_set("n", keys.send_and_clear or "<C-Space>", function() send_logic.send_buffer_and_clear(agent_name, bufnr) end, { desc = "Send buffer and clear (scratch)" })
  safe_set("i", keys.send_and_clear or "<C-Space>", function()
    vim.cmd("stopinsert")
    send_logic.send_buffer_and_clear(agent_name, bufnr)
    if vim.api.nvim_buf_is_valid(bufnr) then vim.cmd("startinsert") end
  end, { desc = "Send buffer and clear (insert mode)" })

  -- Scroll mappings
  safe_set("n", keys.scroll_up or "<C-u>", function()
    local pane = get_pane()
    if pane then backend_mod.scroll_up(pane) end
  end, { desc = "Scroll agent pane up" })
  safe_set("n", keys.scroll_down or "<C-d>", function()
    local pane = get_pane()
    if pane then backend_mod.scroll_down(pane) end
  end, { desc = "Scroll agent pane down" })

  -- Navigation keys
  safe_set("n", keys.nav_up or "<Up>", function()
    send_key_to_pane("Up", false)
  end, { desc = "Send Up to agent pane" })
  safe_set("n", keys.nav_down or "<Down>", function()
    send_key_to_pane("Down", false)
  end, { desc = "Send Down to agent pane" })

  safe_set("i", keys.nav_up or "<Up>", function()
    send_key_to_pane("Up", true)
  end, { desc = "Send Up to agent pane (insert mode)" })
  safe_set("i", keys.nav_down or "<Down>", function()
    send_key_to_pane("Down", true)
  end, { desc = "Send Down to agent pane (insert mode)" })

  -- Escape mapping (normal and insert modes)
  -- safe_set("n", keys.esc or "<Esc>", function()
  --   send_key_to_pane("Escape", false)
  -- end, { desc = "Send Escape to agent pane" })

  if state.opts.send_number_keys_to_agent then
    local function send_number_to_agent(number)
      local p = get_pane()
      if not p then
        local active_agents = agent_logic.get_active_agents()
        if #active_agents == 1 then
          p = state.sessions[active_agents[1]].pane_id
        end
      end

      if p then
        backend_mod.send_keys(p, { tostring(number) })
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

return M
