-- logic/keymaps.lua
-- This module handles the registration of keymaps, both global and buffer-local
-- for scratch buffers.
local M = {}

local state = require("lazyagent.logic.state")
local acp_logic = require("lazyagent.logic.acp")
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
  local preserve_scratch = acp_logic.is_acp_backend(backend_name)

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

  local function resolve_target()
    local resolved_agent = agent_name
    local resolved_pane = get_pane()
    local resolved_backend = backend_name
    local resolved_mod = backend_mod

    if (not resolved_pane or resolved_pane == "") and resolved_agent and state.sessions[resolved_agent] then
      resolved_pane = state.sessions[resolved_agent].pane_id or nil
    end

    if not resolved_pane or resolved_pane == "" then
      local active_agents = agent_logic.get_active_agents()
      if #active_agents == 1 then
        resolved_agent = active_agents[1]
        resolved_pane = state.sessions[resolved_agent] and state.sessions[resolved_agent].pane_id or nil
      end
    end

    if resolved_agent then
      resolved_backend, resolved_mod = backend_logic.resolve_backend_for_agent(resolved_agent, nil)
    end

    if not resolved_mod or not resolved_pane or resolved_pane == "" then
      return nil, nil, nil, nil
    end

    return resolved_agent, resolved_pane, resolved_backend, resolved_mod
  end

  local function with_insert_wrap(insert_wrap, callback)
    local should_restart = insert_wrap and vim.fn.mode():sub(1, 1) == "i"
    if should_restart then
      vim.cmd("stopinsert")
    end
    local result = callback()
    if should_restart then
      restart_insert_if_valid(bufnr)
    end
    return result
  end

  local function buffer_has_content(target_bufnr)
    local lines = vim.api.nvim_buf_get_lines(target_bufnr, 0, -1, false)
    for _, line in ipairs(lines) do
      if line:match("%S") then
        return true
      end
    end
    return false
  end

  local function send_key_to_pane(key, insert_wrap)
    local _, resolved_pane, _, resolved_mod = resolve_target()
    if not resolved_pane then
      return
    end
    with_insert_wrap(insert_wrap, function()
      resolved_mod.send_keys(resolved_pane, { key })
    end)
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

     -- Append custom tag if configured AND in instant mode
    local s = agent_name and state.sessions[agent_name]
    if s and s.mode == "instant" then
       local append_text = (state.opts and state.opts.instant_mode and state.opts.instant_mode.append_text) or nil
       if append_text and append_text ~= "" then
          -- Expand tokens in append_text (e.g., #translate)
          local expanded_append = transforms.expand(append_text, { source_bufnr = source_bufnr, scratch_bufnr = bufnr })
          append_text = expanded_append or append_text

          -- Ensure we append nicely (with space if needed, avoid double space)
          if not text:match("%s$") and not append_text:match("^%s") then
             text = text .. " " .. append_text
          else
             text = text .. append_text
          end
       end
    end

    if text and #text > 0 then
      local submit_keys = config.pref(agent_cfg, "submit_keys", nil)
      local submit_delay = config.pref(agent_cfg, "submit_delay", 600)
      local submit_retry = config.pref(agent_cfg, "submit_retry", 1)
      -- Save scratch content to cache on send
      cache_logic.write_scratch_to_cache(bufnr)
      local _send_mode = config.pref(agent_cfg, "send_mode", nil)
      local _move_to_end = (_send_mode == "append")
      local _use_bracketed_paste = config.pref(agent_cfg, "use_bracketed_paste", nil)
      local submit_result = backend_mod.paste_and_submit(pane, text, submit_keys, {
        submit_delay = submit_delay,
        submit_retry = submit_retry,
        debug = state.opts.debug,
        move_to_end = _move_to_end,
        use_bracketed_paste = _use_bracketed_paste,
      })
      if submit_result == false then
        return
      end
      pcall(function() vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {}) end)

      -- Start monitoring for completion (spinner/loader) if appropriate
      local status_logic = require("lazyagent.logic.status")
      if submit_result == true and not (state.opts and state.opts.mcp_mode) then
        status_logic.start_monitor(agent_name)
      end

      if submit_result == true and (close_after or state.opts.close_on_send) then
        window.close({ keep_buffer = preserve_scratch })
        if not preserve_scratch and bufnr and vim.api.nvim_buf_is_valid(bufnr) then
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

  local function interrupt_agent(insert_wrap)
    local resolved_agent, resolved_pane, resolved_backend, resolved_mod = resolve_target()
    if not resolved_pane then
      vim.notify("No active agent pane found to interrupt", vim.log.levels.WARN)
      return
    end

    with_insert_wrap(insert_wrap, function()
      send_logic.send_interrupt({
        agent_name = resolved_agent,
        pane_id = resolved_pane,
        backend_name = resolved_backend,
        backend_mod = resolved_mod,
        silent = true,
      })
    end)
  end

  safe_set("n", keys.interrupt or "<C-c>", function()
    interrupt_agent(false)
  end, { desc = "Send Ctrl-C (interrupt) to agent" })
  safe_set("i", keys.interrupt or "<C-c>", function()
    interrupt_agent(true)
  end, { desc = "Send Ctrl-C (interrupt) to agent" })

  -- Close mapping
  safe_set("n", keys.close or "q", function()
    local closed = window.close({ keep_buffer = preserve_scratch })
    if not closed then return end
    if not preserve_scratch and bufnr and vim.api.nvim_buf_is_valid(bufnr) then
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
  local function smart_send(insert_mode)
    if buffer_has_content(bufnr) then
      with_insert_wrap(insert_mode, function()
        send_logic.send_buffer_and_clear(agent_name, bufnr)
      end)
    else
      send_key_to_pane("Enter", insert_mode)
    end
  end

  safe_set("n", keys.send_and_clear or "<C-Space>", function()
    smart_send(false)
  end, { desc = "Send buffer and clear (scratch)" })
  safe_set("i", keys.send_and_clear or "<C-Space>", function()
    smart_send(true)
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

  local function resume_follow()
    local _, resolved_pane, resolved_backend, resolved_mod = resolve_target()
    if not resolved_pane then
      vim.notify("No active agent pane found", vim.log.levels.WARN)
      return
    end

    if resolved_backend ~= "buffer_acp" and resolved_backend ~= "tmux_acp" then
      vim.notify("adjust_line is only available for ACP sessions", vim.log.levels.WARN)
      return
    end

    resolved_mod.send_keys(resolved_pane, { "Escape" })
  end

  -- Escape mapping (normal)
  safe_set("n", keys.esc or "<Esc>", function()
    send_key_to_pane("Escape", false)
  end, { desc = "Send Escape to agent pane" })

  if keys.adjust_line then
    safe_set("n", keys.adjust_line, function()
      resume_follow()
    end, { desc = "Resume ACP transcript follow" })
  end

  safe_set("n", keys.clear or "c<space>d", function()
    local resolved_agent, resolved_pane, resolved_backend, resolved_mod = resolve_target()
    if not resolved_pane then
      return
    end
    send_logic.clear_input({
      agent_name = resolved_agent,
      pane_id = resolved_pane,
      backend_name = resolved_backend,
      backend_mod = resolved_mod,
      silent = true,
    })
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

  -- Stack (save and clear) current scratch buffer content to history
  safe_set("n", keys.stack or "c<space>s", function()
    if buffer_has_content(bufnr) then
      cache_logic.write_scratch_to_cache(bufnr)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
      vim.notify("Stacked to history", vim.log.levels.INFO)
    else
      vim.notify("Buffer empty", vim.log.levels.INFO)
    end
  end, { desc = "Stack (save and clear) scratch buffer" })

  local function apply_history_offset(direction)
    local list_buf = cache_logic.get_history_list_buf_for_target(bufnr)
    local entries = cache_logic.read_history_entries(list_buf) or {}
    if not entries or #entries == 0 then
      return
    end

    local cur = vim.b[bufnr].lazyagent_history_idx or 0
    local next_idx
    if direction > 0 then
      next_idx = buffer_has_content(bufnr) and (cur + 1) or 1
    else
      if cur <= 1 then
        return
      end
      next_idx = cur - 1
    end

    if next_idx < 1 then
      next_idx = 1
    end

    if next_idx > #entries then
      return
    end

    local ok, total = cache_logic.apply_history_entry_to_target_buf(bufnr, next_idx)
    if not ok and total > 0 then
      vim.notify("LazyAgentHistory: failed to apply entry", vim.log.levels.ERROR)
    end
  end

  -- Navigate to older entry (scratch buffer) - default: keys.history_prev or <leader>h,
  safe_set("n", keys.history_prev or "c<space>p", function()
    apply_history_offset(1)
  end, { desc = "Apply older cached history to scratch buffer" })

  -- Navigate to newer entry (scratch buffer) - default: keys.history_next or <leader>h.
  safe_set("n", keys.history_next or "c<space>n", function()
    apply_history_offset(-1)
  end, { desc = "Apply newer cached history to scratch buffer" })

  -- Custom mappings for user request (C-j/k for navigation, C-Space for Enter)
  safe_set("n", "<C-j>", function() 
    -- vim.notify("DEBUG: C-j pressed", vim.log.levels.INFO)
    send_key_to_pane("Down", false) 
  end, { desc = "Send Down" })
  safe_set("i", "<C-j>", function() 
    -- vim.notify("DEBUG: C-j (insert) pressed", vim.log.levels.INFO)
    send_key_to_pane("Down", true) 
  end, { desc = "Send Down (insert)" })
  safe_set("n", "<C-k>", function() send_key_to_pane("Up", false) end, { desc = "Send Up" })
  safe_set("i", "<C-k>", function() send_key_to_pane("Up", true) end, { desc = "Send Up (insert)" })
end

return M
