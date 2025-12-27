-- logic/keymaps.lua
-- This module handles the registration of keymaps, both global and buffer-local
-- for scratch buffers.
local M = {}

local state = require("lazyagent.logic.state")
local agent_logic = require("lazyagent.logic.agent")
local backend_logic = require("lazyagent.logic.backend")
local send_logic = require("lazyagent.logic.send")
local window = require("lazyagent.window")
local cache_logic = require("lazyagent.logic.cache")
local config = require("lazyagent.logic.config")

local function restart_insert_if_valid(bufnr)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.cmd("startinsert")
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

  local backend_name, backend_mod = backend_logic.resolve_backend_for_agent(agent_name, agent_cfg)

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
    if insert_wrap then restart_insert_if_valid(bufnr) end
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
      local submit_keys = config.pref(agent_cfg, "submit_keys", nil)
      local submit_delay = config.pref(agent_cfg, "submit_delay", 600)
      local submit_retry = config.pref(agent_cfg, "submit_retry", 1)
      -- Save scratch content to cache on send
      cache_logic.write_scratch_to_cache(bufnr)
      local _send_mode = config.pref(agent_cfg, "send_mode", nil)
      local _move_to_end = (_send_mode == "append")
      local _use_bracketed_paste = config.pref(agent_cfg, "use_bracketed_paste", nil)
      backend_mod.paste_and_submit(pane, text, submit_keys, {
        submit_delay = submit_delay,
        submit_retry = submit_retry,
        debug = state.opts.debug,
        move_to_end = _move_to_end,
        use_bracketed_paste = _use_bracketed_paste,
      })
      pcall(function() vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {}) end)
      if close_after or state.opts.close_on_send then
        window.close()
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
          vim.api.nvim_buf_delete(bufnr, { force = true })
        end
        state.open_agent = nil
        if agent_name and state.sessions[agent_name] and state.sessions[agent_name].pane_id and not reuse then
          local session_logic = require("lazyagent.logic.session") -- require here to avoid circular dependency
          session_logic.close_session(agent_name)
        end
      end
    end
  end

  -- clear mapping: attempt to clear the agent pane's input (tmux / builtin)
  local function clear_agent_pane_input(insert_wrap)
    -- Determine pane id (explicit or session-based)
    local p = get_pane()
    if not p or p == "" then
      -- fallback: if exactly one active agent is running, target its pane
      local active_agents = agent_logic.get_active_agents()
      if #active_agents == 1 then
        p = state.sessions[active_agents[1]] and state.sessions[active_agents[1]].pane_id or nil
      end
    end

    if not p or p == "" then return end

    if insert_wrap and vim.fn.mode():sub(1,1) == "i" then
      vim.cmd("stopinsert")
    end

    -- For tmux backend, send 'C-e', 'C-u', 'C-h' (tmux translates this to ctrl-u).
    -- For builtin or other backends (non-tmux), send the literal ASCII ctrl-u char.
    if backend_name == "tmux" then
      -- backend_mod.send_keys(p, { "C-e", "C-u", "C-h" })
      backend_mod.send_keys(p, { "C-e" })
      vim.wait(25)
      backend_mod.send_keys(p, { "C-u" })
      vim.wait(25)
      backend_mod.send_keys(p, { "C-h" })
    else
      -- ASCII 5 is C-e, 21 is C-u
      backend_mod.send_keys(p, { string.char(5), string.char(21) })
    end

    if insert_wrap then restart_insert_if_valid(bufnr) end
  end

  -- Close mapping
  safe_set("n", keys.close or "q", function()
    local closed = window.close()
    if not closed then return end
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
    state.open_agent = nil
    if agent_name and state.sessions[agent_name] and state.sessions[agent_name].pane_id and not reuse then
      local session_logic = require("lazyagent.logic.session") -- require here to avoid circular dependency
      session_logic.close_session(agent_name)
    end
  end, { nowait = true, desc = "Close input buffer"  })

  -- Submit mappings (normal / insert)
  safe_set("n", keys.send_key_normal or "<CR>", function() send_from_buf() end, { desc = "Submit from buffer" })
  safe_set("i", keys.send_key_insert or "<C-s>", function()
    vim.cmd("stopinsert")
    send_from_buf()
    restart_insert_if_valid(bufnr)
  end, { desc = "Submit from insert mode" })

  -- Send & clear (scratch)
  safe_set("n", keys.send_and_clear or "<C-Space>", function()
    send_logic.send_buffer_and_clear(agent_name, bufnr)
  end, { desc = "Send buffer and clear (scratch)" })
  safe_set("i", keys.send_and_clear or "<C-Space>", function()
    vim.cmd("stopinsert")
    send_logic.send_buffer_and_clear(agent_name, bufnr)
    restart_insert_if_valid(bufnr)
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

  -- Escape mapping (normal)
  safe_set("n", keys.esc or "<Esc>", function()
    if (agent_name == "Cursor") then
      send_key_to_pane("C-c", false)
    else
      send_key_to_pane("Escape", false)
    end
  end, { desc = "Send Escape to agent pane" })

  safe_set("n", keys.clear or "c<space>d", function()
    clear_agent_pane_input(false)
  end, { desc = "Clear agent pane input" })

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

  -- Navigate to older entry (scratch buffer) - default: keys.history_prev or <leader>h,
  safe_set("n", keys.history_prev or "c<space>p", function()
    local list_buf = cache_logic.get_history_list_buf_for_target(bufnr)
    local entries = cache_logic.read_history_entries(list_buf) or {}
    if not entries or #entries == 0 then
      vim.notify("LazyAgentHistory: no cached entries found", vim.log.levels.INFO)
      return
    end

    -- If the buffer is empty (or whitespace only), start from the latest entry (1).
    -- This handles the case where the buffer was cleared after sending (idx=1 but content is empty).
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local is_empty = true
    for _, line in ipairs(lines) do
      if line:match("%S") then
        is_empty = false
        break
      end
    end

    local cur = vim.b[bufnr].lazyagent_history_idx or 0
    local next_idx = cur + 1
    if is_empty then
      next_idx = 1
    end

    if next_idx > #entries then
      vim.notify("LazyAgentHistory: already at oldest entry", vim.log.levels.INFO)
      return
    end
    local ok, total = cache_logic.apply_history_entry_to_target_buf(bufnr, next_idx)
    if ok then
      vim.notify("LazyAgentHistory: applied " .. tostring(next_idx) .. "/" .. tostring(total), vim.log.levels.INFO)
    else
      if total == 0 then
        vim.notify("LazyAgentHistory: no cached entries found", vim.log.levels.INFO)
      else
        vim.notify("LazyAgentHistory: failed to apply entry", vim.log.levels.ERROR)
      end
    end
    -- restart_insert_if_valid(bufnr)
  end, { desc = "Apply older cached history to scratch buffer" })

  -- Navigate to newer entry (scratch buffer) - default: keys.history_next or <leader>h.
  safe_set("n", keys.history_next or "c<space>n", function()
    local list_buf = cache_logic.get_history_list_buf_for_target(bufnr)
    local entries = cache_logic.read_history_entries(list_buf) or {}
    if not entries or #entries == 0 then
      vim.notify("LazyAgentHistory: no cached entries found", vim.log.levels.INFO)
      return
    end
    local cur = vim.b[bufnr].lazyagent_history_idx or 0
    if cur <= 1 then
      vim.notify("LazyAgentHistory: already at latest entry", vim.log.levels.INFO)
      return
    end
    local next_idx = cur - 1
    local ok, total = cache_logic.apply_history_entry_to_target_buf(bufnr, next_idx)
    if ok then
      vim.notify("LazyAgentHistory: applied " .. tostring(next_idx) .. "/" .. tostring(total), vim.log.levels.INFO)
    else
      if total == 0 then
        vim.notify("LazyAgentHistory: no cached entries found", vim.log.levels.INFO)
      else
        vim.notify("LazyAgentHistory: failed to apply entry", vim.log.levels.ERROR)
      end
    end
    -- restart_insert_if_valid(bufnr)
  end, { desc = "Apply newer cached history to scratch buffer" })
end

return M
