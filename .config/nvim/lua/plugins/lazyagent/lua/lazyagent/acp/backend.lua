
local M = {}

local cache_logic = require("lazyagent.logic.cache")
local ACPClient = require("lazyagent.acp.client")
local local_commands = require("lazyagent.acp.local_commands")
local agent_logic = require("lazyagent.logic.agent")
local acp_logic = require("lazyagent.logic.acp")
local diff_utils = require("lazyagent.acp.diff")
local skills_logic = require("lazyagent.logic.skills")
local summary_logic = require("lazyagent.logic.summary")
local transforms = require("lazyagent.transforms")
local util = require("lazyagent.util")
local state = require("lazyagent.logic.state")
local backend_state = require("lazyagent.acp.backend.state")
local backend_conversation = require("lazyagent.acp.backend.conversation")
local backend_config = require("lazyagent.acp.backend.config")
local backend_actions = require("lazyagent.acp.backend.actions")
local backend_host = require("lazyagent.acp.backend.host")

local sessions = {}
local section_icons = {
  User = "󰍩",
  Assistant = "󰭹",
  Thinking = "󰔟",
  System = "󰋽",
  Error = "󰅚",
  Plan = "󰐕",
}
local SWITCH_HISTORY_RECENT_ITEMS = 14
local SWITCH_HISTORY_ITEM_BODY_LIMIT = 6000
local SWITCH_HISTORY_TOOL_LIMIT = 6
local SWITCH_HISTORY_TRANSCRIPT_BYTE_LIMIT = 128 * 1024

local function get_session(pane_id)
  return sessions[pane_id]
end

local function normalize_text(text)
  return util.normalize_text(text, { ensure_trailing_newline = false })
end

local sanitize_filename_component = util.sanitize_filename_component

local state_helpers
local conversation_helpers
local config_helpers
local actions_helpers
local host_helpers
local complete_pending_turn

state_helpers = backend_state.setup({
  cache_logic = cache_logic,
  util = util,
  state = state,
  normalize_text = normalize_text,
  append_block = function(...)
    return conversation_helpers.append_block(...)
  end,
})

conversation_helpers = backend_conversation.setup({
  diff_utils = diff_utils,
  normalize_text = normalize_text,
  file_uri = state_helpers.file_uri,
  write_session_transcript = state_helpers.write_session_transcript,
  sync_runtime_live_state = function(...)
    return state_helpers.sync_runtime_live_state(...)
  end,
  section_icons = section_icons,
  switch_history_recent_items = SWITCH_HISTORY_RECENT_ITEMS,
  switch_history_item_body_limit = SWITCH_HISTORY_ITEM_BODY_LIMIT,
  switch_history_tool_limit = SWITCH_HISTORY_TOOL_LIMIT,
  switch_history_transcript_byte_limit = SWITCH_HISTORY_TRANSCRIPT_BYTE_LIMIT,
})

config_helpers = backend_config.setup({
  state = state,
  acp_logic = acp_logic,
  agent_logic = agent_logic,
  skills_logic = skills_logic,
  local_commands = local_commands,
  transforms = transforms,
  normalize_text = normalize_text,
  append_block = function(...)
    return conversation_helpers.append_block(...)
  end,
  sync_runtime_session = function(...)
    return state_helpers.sync_runtime_session(...)
  end,
  first_nonempty = state_helpers.first_nonempty,
  item_body_text = function(...)
    return conversation_helpers.item_body_text(...)
  end,
  matches_exact = conversation_helpers.matches_exact,
  matches_pattern = conversation_helpers.matches_pattern,
})

actions_helpers = backend_actions.setup({
  state = state,
  agent_logic = agent_logic,
  local_commands = local_commands,
  cache_logic = cache_logic,
  summary_logic = summary_logic,
  sanitize_filename_component = sanitize_filename_component,
  file_uri = state_helpers.file_uri,
  read_path_lines = state_helpers.read_path_lines,
  reload_loaded_buffers_for_path = state_helpers.reload_loaded_buffers_for_path,
  normalize_text = normalize_text,
  append_block = function(...)
    return conversation_helpers.append_block(...)
  end,
  render_tool_content = conversation_helpers.render_tool_content,
  render_tool_raw_output = conversation_helpers.render_tool_raw_output,
  extract_tool_paths = conversation_helpers.extract_tool_paths,
  summarize_tool = conversation_helpers.summarize_tool,
  normalize_tool_path = conversation_helpers.normalize_tool_path,
  config_option_current_name = config_helpers.config_option_current_name,
  config_option_kind = config_helpers.config_option_kind,
  config_option_category = config_helpers.config_option_category,
  config_option_description = config_helpers.config_option_description,
  config_option_title = config_helpers.config_option_title,
  show_config_picker_for_session = config_helpers.show_config_picker_for_session,
  session_has_available_command = function(...)
    return config_helpers.session_has_available_command and config_helpers.session_has_available_command(...)
  end,
})

host_helpers = backend_host.setup({
  ACPClient = ACPClient,
  state = state,
  acp_logic = acp_logic,
  util = util,
  normalize_text = normalize_text,
  build_transcript_path = state_helpers.build_transcript_path,
  clamp_utf8_from_end = state_helpers.clamp_utf8_from_end,
  ensure_parent_dir = state_helpers.ensure_parent_dir,
  read_path_lines = state_helpers.read_path_lines,
  read_buffer_lines_for_path = state_helpers.read_buffer_lines_for_path,
  reload_loaded_buffers_for_path = state_helpers.reload_loaded_buffers_for_path,
  write_session_transcript = state_helpers.write_session_transcript,
  sync_runtime_session = state_helpers.sync_runtime_session,
  update_session_info = state_helpers.update_session_info,
  update_usage_stats = state_helpers.update_usage_stats,
  normalize_session_info = state_helpers.normalize_session_info,
  assistant_heading_label = config_helpers.assistant_heading_label,
  apply_initial_session_config = config_helpers.apply_initial_session_config,
  maybe_save_turn_to_brain = config_helpers.maybe_save_turn_to_brain,
  complete_pending_turn = function(session)
    if type(complete_pending_turn) == "function" then
      return complete_pending_turn(session)
    end
    return false
  end,
  normalize_available_commands = config_helpers.normalize_available_commands,
  note_unadvertised_slash_command = config_helpers.note_unadvertised_slash_command,
  build_switch_history_blocks = conversation_helpers.build_switch_history_blocks,
  build_prompt_blocks = actions_helpers.build_prompt_blocks,
  append_block = conversation_helpers.append_block,
  append_stream_chunk = conversation_helpers.append_stream_chunk,
  close_stream = conversation_helpers.close_stream,
  render_content = conversation_helpers.render_content,
  render_tool_content = conversation_helpers.render_tool_content,
  render_tool_raw_output = conversation_helpers.render_tool_raw_output,
  summarize_tool_block = conversation_helpers.summarize_tool_block,
  extract_tool_paths = conversation_helpers.extract_tool_paths,
  merge_tool_update = conversation_helpers.merge_tool_update,
  tool_update_is_terminal = conversation_helpers.tool_update_is_terminal,
  tool_heading = conversation_helpers.tool_heading,
  resolve_permission_rule = conversation_helpers.resolve_permission_rule,
  clear_pending_switch_history = state_helpers.clear_pending_switch_history,
  render_permission_preview = actions_helpers.render_permission_preview,
  maybe_call_mcp_tool = actions_helpers.maybe_call_mcp_tool,
  maybe_sync_acp_edit_targets = actions_helpers.maybe_sync_acp_edit_targets,
})

local function create_backend(default_view)
  local backend = {}

  complete_pending_turn = function(session)
    local pending = session and session.pending_brain_turn or nil
    if not pending then
      return false
    end
    session.pending_brain_turn = nil
    util.fire_event("AssistantResponse", { agent_name = session.agent_name, result = pending.result })
    util.fire_event("TurnDone", { agent_name = session.agent_name, result = pending.result })
    actions_helpers.maybe_call_mcp_tool("notify_done", { agent_name = session.agent_name })
    config_helpers.maybe_save_turn_to_brain(session, pending.prompt, pending.start_seq)
    return true
  end

  local function session_view(session)
    return (session and session.view) or default_view
  end

  function backend._drain_prompt_queue(pane_id)
    local session = get_session(pane_id)
    if not session or session.failed or session.busy or session.preparing_prompt or not session.ready or not session.client then
      return false
    end

    local prompt = table.remove(session.prompt_queue, 1)
    if not prompt then
      return false
    end

    session.preparing_prompt = true
    config_helpers.maybe_apply_auto_switch(session, prompt, function()
      if next(session.tool_calls or {}) == nil then
        complete_pending_turn(session)
      end
      session.preparing_prompt = false
      session.busy = true
      actions_helpers.maybe_call_mcp_tool("notify_start", { agent_name = session.agent_name })
      config_helpers.note_unadvertised_slash_command(session, prompt)
      local view = session_view(session)
      if view and type(view.resume_follow) == "function" then
        view.resume_follow(pane_id)
      end
      conversation_helpers.append_block(session, "User", prompt)
      local turn_start_seq = #session.conversation_timeline

      local blocks = {}
      if session.pending_switch_history then
        vim.list_extend(blocks, conversation_helpers.build_switch_history_blocks(session, session.pending_switch_history))
      end
      vim.list_extend(blocks, actions_helpers.build_prompt_blocks(session, prompt))
      session.client:send_prompt(blocks, function(result, err)
        session.busy = false
        conversation_helpers.close_stream(session)

        if err then
          session.pending_brain_turn = nil
          conversation_helpers.append_block(session, "Error", err.message or tostring(err))
          pcall(function()
            require("lazyagent.logic.status").set_waiting(session.agent_name, "ACP error")
          end)
          session.prompt_queue = {}
          return
        end

        if session.pending_switch_history then
          state_helpers.clear_pending_switch_history(session)
        end

        local stop_reason = result and result.stopReason or nil
        if stop_reason == "tool_call" then
          session.pending_brain_turn = {
            prompt = prompt,
            start_seq = turn_start_seq,
            result = result,
            token = 0,
          }
          pcall(function()
            require("lazyagent.logic.status").start_monitor(session.agent_name)
          end)
          return
        end

        if stop_reason and stop_reason ~= "end_turn" then
          conversation_helpers.append_block(session, "System", "Turn finished with stopReason: " .. tostring(stop_reason))
        end

        session.pending_brain_turn = {
          prompt = prompt,
          start_seq = turn_start_seq,
          result = result,
        }
        complete_pending_turn(session)

        if #session.prompt_queue > 0 then
          backend._drain_prompt_queue(pane_id)
        end
      end)
    end)

    return true
  end

  function backend.configure_pane(pane_id, opts)
    local session = get_session(pane_id)
    local view = session_view(session)
    if view and type(view.configure_pane) == "function" then
      return view.configure_pane(pane_id, opts, session)
    end
    return false
  end

  function backend.clear_pane_config(pane_id)
    local session = get_session(pane_id)
    local view = session_view(session)
    if view and type(view.clear_pane_config) == "function" then
      return view.clear_pane_config(pane_id, session)
    end
    return false
  end

  function backend.split(_, size, is_vertical, on_split_or_opts)
    local on_split = on_split_or_opts
    local opts = {}
    if type(on_split_or_opts) == "table" then
      opts = on_split_or_opts
      on_split = opts.on_split
    end

    local acp = opts.acp or {}
    if not acp.agent_name or not acp.command then
      if on_split then
        vim.schedule(function()
          on_split(nil)
        end)
      end
      return
    end

    local view = default_view
    if not view or type(view.create_pane) ~= "function" then
      if on_split then
        vim.schedule(function()
          on_split(nil)
        end)
      end
      return
    end

    local transcript_path = state_helpers.build_transcript_path(acp.agent_name, acp.source_bufnr)
    local initial_text = conversation_helpers.render_section_block("System", "Connecting ACP session for " .. acp.agent_name .. "...")
    state_helpers.write_transcript(transcript_path, "", "w")
    state_helpers.write_transcript(transcript_path, initial_text, "a")

    view.create_pane({
      acp = acp,
      opts = opts,
      size = size,
      is_vertical = is_vertical,
      transcript_path = transcript_path,
      initial_text = initial_text,
    }, function(pane_id, view_state)
      if not pane_id or pane_id == "" then
        if on_split then
          on_split(nil)
        end
        return
      end

      sessions[pane_id] = {
        pane_id = pane_id,
        agent_name = acp.agent_name,
        agent_cfg = acp.agent_cfg or {},
        transcript_path = transcript_path,
        transcript_has_content = true,
        current_stream_key = nil,
        current_stream_heading = nil,
        current_stream_at_line_start = nil,
        prompt_queue = {},
        tool_calls = {},
        terminals = {},
        available_commands = {},
        config_options = {},
        on_ready_actions = {},
        permission_rules = vim.deepcopy(acp.permission_rules or {}),
        auto_switch = vim.deepcopy(acp.auto_switch or {}),
        manual_config_overrides = {},
        auto_switch_state = {},
        conversation_timeline = {},
        conversation_timeline_index = {},
        conversation_next_item_id = 0,
        tool_timeline = {},
        tool_timeline_index = {},
        ready = false,
        failed = false,
        busy = false,
        preparing_prompt = false,
        command = acp.command,
        env = acp.env or {},
        cwd = acp.cwd or vim.fn.getcwd(),
        root_dir = acp.root_dir,
        mcp_url = acp.mcp_url,
        session_bootstrap = vim.deepcopy(acp.session_bootstrap),
        auto_permission = acp.auto_permission,
        default_mode = acp.default_mode,
        initial_model = acp.initial_model,
        fancy_mode = acp.fancy_mode,
        table_layout = acp.table_layout,
        smooth_scroll = vim.deepcopy(acp.smooth_scroll or {}),
        release_buffer_on_hide = acp.release_buffer_on_hide,
        footer_animation = acp.footer_animation,
        buffer_background = acp.buffer_background,
        buffer_inactive_background = acp.buffer_inactive_background,
        transcript_max_lines = acp.transcript_max_lines,
        render_markdown_max_lines = acp.render_markdown_max_lines,
        transcript_compaction = vim.deepcopy(acp.transcript_compaction or {}),
        runtime_compaction = vim.deepcopy(acp.runtime_compaction or {}),
        initial_config_applied = false,
        session_info = {},
        usage_stats = {},
        view = view,
        view_state = view_state or {},
      }
      conversation_helpers.new_conversation_item(
        sessions[pane_id],
        "System",
        "Connecting ACP session for " .. acp.agent_name .. "..."
      )

      if type(view.on_session_created) == "function" then
        view.on_session_created(sessions[pane_id])
      end
      host_helpers.start_client(sessions[pane_id], {
        drain_prompt_queue = function(target_pane)
          backend._drain_prompt_queue(target_pane)
        end,
      })
      if on_split then
        on_split(pane_id)
      end
    end)
  end

  function backend.pane_exists(pane_id)
    local session = get_session(pane_id)
    if not session then
      return false
    end
    local view = session_view(session)
    if view and type(view.pane_exists) == "function" then
      return view.pane_exists(pane_id, session)
    end
    return true
  end

  function backend.get_pane_pid(pane_id)
    local session = get_session(pane_id)
    if session and session.client and session.client.pid then
      return session.client.pid
    end
    return nil
  end

  function backend.get_runtime_snapshot(pane_id, opts)
    if opts == true then
      opts = { full = true }
    end
    opts = opts or {}
    local session = get_session(pane_id)
    if not session then
      return nil
    end

    local snapshot = {
      pane_id = session.pane_id,
      cwd = session.cwd,
      root_dir = session.root_dir,
      transcript_path = session.transcript_path,
      footer_animation = session.footer_animation,
      fancy_mode = session.fancy_mode,
      release_buffer_on_hide = session.release_buffer_on_hide,
      buffer_background = session.buffer_background,
      buffer_inactive_background = session.buffer_inactive_background,
      transcript_max_lines = session.transcript_max_lines,
      render_markdown_max_lines = session.render_markdown_max_lines,
      transcript_compaction = vim.deepcopy(session.transcript_compaction or {}),
      runtime_compaction = vim.deepcopy(session.runtime_compaction or {}),
      acp_available_commands = vim.deepcopy(session.available_commands or {}),
      acp_config_options = vim.deepcopy(session.config_options or {}),
      acp_session_id = session.session_id,
      acp_session_info = vim.deepcopy(session.session_info or {}),
      acp_transcript_path = session.transcript_path,
      acp_agent_info = vim.deepcopy(session.agent_info or {}),
      acp_agent_capabilities = vim.deepcopy(session.agent_capabilities or {}),
      acp_session_capabilities = vim.deepcopy((session.agent_capabilities and session.agent_capabilities.sessionCapabilities) or {}),
      acp_model_catalog = vim.deepcopy(session.model_catalog or {}),
      acp_mode_catalog = vim.deepcopy(session.mode_catalog or {}),
      acp_usage_stats = vim.deepcopy(session.usage_stats or {}),
      acp_ready = session.ready == true,
      acp_failed = session.failed == true,
      acp_supports_embedded_context = session.prompt_supports_embedded_context == true,
      acp_mcp_server_count = session.mcp_server_count or ((session.mcp_url and session.mcp_url ~= "") and 1 or 0),
      acp_permission_rules = vim.deepcopy(session.permission_rules or {}),
      acp_auto_switch = vim.deepcopy(session.auto_switch or {}),
      acp_manual_config_overrides = vim.deepcopy(session.manual_config_overrides or {}),
      source_winid = session.view_state and session.view_state.source_winid or nil,
    }
    if opts.full == true or opts.include_timelines == true then
      snapshot.acp_tool_timeline = vim.deepcopy(session.tool_timeline or {})
      snapshot.acp_conversation_timeline = vim.deepcopy(session.conversation_timeline or {})
    end
    return snapshot
  end

  function backend.capture_switch_view(pane_id)
    local session = get_session(pane_id)
    local view = session_view(session)
    if view and type(view.capture_switch_view) == "function" then
      return view.capture_switch_view(pane_id, session)
    end
    return nil
  end

  function backend.send_keys(pane_id, keys)
    local session = get_session(pane_id)
    if not session or not keys then
      return false
    end
    if type(keys) ~= "table" then
      keys = { keys }
    end
    local literal_mode = false

    for _, key in ipairs(keys) do
      local normalized = tostring(key)
      if normalized == "--literal" then
        literal_mode = true
      elseif normalized == "C-c" or normalized == string.char(3) then
        if session.client then
          session.client:cancel()
          conversation_helpers.append_block(session, "System", "Cancellation requested")
        end
        return true
      elseif normalized == "Up" then
        if session.view and type(session.view.scroll_up) == "function" then
          return session.view.scroll_up(pane_id)
        end
        return true
      elseif normalized == "Down" then
        if session.view and type(session.view.scroll_down) == "function" then
          return session.view.scroll_down(pane_id)
        end
        return true
      elseif normalized == "Escape" then
        if session.view and type(session.view.resume_follow) == "function" then
          return session.view.resume_follow(pane_id)
        end
        return true
      elseif normalized:match("^%d$") or (literal_mode and #normalized > 0) then
        backend.paste_and_submit(pane_id, normalized, { "C-m" }, {})
        return true
      end
    end

    return true
  end

  function backend.kill_pane(pane_id)
    local session = get_session(pane_id)
    if session then
      if next(session.tool_calls or {}) == nil then
        complete_pending_turn(session)
      end
      state_helpers.clear_pending_switch_history(session)
      session.closing_intentionally = true
      for terminal_id, _ in pairs(session.terminals or {}) do
        pcall(host_helpers.terminal_release, session, { terminalId = terminal_id })
      end
      local view = session_view(session)
      if view and type(view.kill_pane) == "function" then
        view.kill_pane(pane_id, session)
      end
      state_helpers.release_closing_session_memory(session)
      sessions[pane_id] = nil
      if session.client then
        local client = session.client
        local stopped = false
        local stop_client = function()
          if stopped then
            return
          end
          stopped = true
          client:stop()
        end

        if client:supports_session_close() and session.session_id and session.session_id ~= "" then
          client:close_session(session.session_id, function()
            stop_client()
          end)
          vim.defer_fn(function()
            if client:is_connected() then
              stop_client()
            end
          end, 1000)
        else
          stop_client()
        end
      end
      return
    end

    local view = session_view(nil)
    if view and type(view.kill_pane) == "function" then
      view.kill_pane(pane_id, nil)
    end
  end

  function backend.kill_pane_sync(pane_id)
    backend.kill_pane(pane_id)
  end

  function backend.get_pane_info(pane_id, on_info)
    local session = get_session(pane_id)
    local view = session_view(session)
    if view and type(view.get_pane_info) == "function" then
      return view.get_pane_info(pane_id, on_info, session)
    end
    if on_info then
      vim.schedule(function()
        on_info(nil)
      end)
    end
    return false
  end

  function backend.is_busy(target_pane)
    local session = get_session(target_pane)
    if not session then
      return false
    end
    return session.busy == true
      or session.preparing_prompt == true
      or (type(session.prompt_queue) == "table" and #session.prompt_queue > 0)
  end

  function backend.restore_switch_snapshot(target_pane, snapshot)
    local session = get_session(target_pane)
    if not session then
      return false
    end
    return state_helpers.restore_switch_snapshot(session, snapshot)
  end

  function backend.break_pane(pane_id)
    local session = get_session(pane_id)
    local view = session_view(session)
    if view and type(view.break_pane) == "function" then
      return view.break_pane(pane_id, session)
    end
    return false
  end

  function backend.break_pane_sync(pane_id)
    local session = get_session(pane_id)
    local view = session_view(session)
    if view and type(view.break_pane_sync) == "function" then
      return view.break_pane_sync(pane_id, session)
    end
    return backend.break_pane(pane_id)
  end

  function backend.open_fullscreen_transcript(pane_id)
    local session = get_session(pane_id)
    local view = session_view(session)
    if view and type(view.open_fullscreen_transcript) == "function" then
      return view.open_fullscreen_transcript(pane_id, session)
    end
    return false
  end

  function backend.join_pane(pane_id, size, is_vertical, on_done)
    local session = get_session(pane_id)
    local view = session_view(session)
    if view and type(view.join_pane) == "function" then
      return view.join_pane(pane_id, size, is_vertical, on_done, session)
    end
    if on_done then
      vim.schedule(function()
        on_done(false)
      end)
    end
    return false
  end

  function backend.copy_mode(pane_id)
    local session = get_session(pane_id)
    local view = session_view(session)
    if view and type(view.copy_mode) == "function" then
      return view.copy_mode(pane_id, session)
    end
    return false
  end

  function backend.scroll_up(pane_id)
    local session = get_session(pane_id)
    local view = session_view(session)
    if view and type(view.scroll_up) == "function" then
      return view.scroll_up(pane_id, session)
    end
    return false
  end

  function backend.scroll_down(pane_id)
    local session = get_session(pane_id)
    local view = session_view(session)
    if view and type(view.scroll_down) == "function" then
      return view.scroll_down(pane_id, session)
    end
    return false
  end

  function backend.cleanup_if_idle()
    local view = session_view(nil)
    if view and type(view.cleanup_if_idle) == "function" then
      return view.cleanup_if_idle()
    end
    return false
  end

  function backend.paste(target_pane, opts)
    opts = opts or {}
    return backend.paste_and_submit(target_pane, opts.text or "", { "C-m" }, opts)
  end

  function backend.paste_and_submit(target_pane, text, _, _)
    local session = get_session(target_pane)
    if not session then
      return false
    end
    if session.failed then
      conversation_helpers.append_block(session, "Error", "ACP session is disconnected. Restart the agent session to continue.")
      return false
    end

    local prompt = normalize_text(text or "")
    if prompt == "" then
      return true
    end
    if prompt:match("\n$") then
      prompt = prompt:gsub("\n+$", "")
    end
    if actions_helpers.handle_local_slash_command(session, prompt) then
      return "handled"
    end
    table.insert(session.prompt_queue, prompt)
    backend._drain_prompt_queue(target_pane)
    return true
  end

  function backend.show_config_picker(target_pane, category)
    local session = get_session(target_pane)
    if not session then
      return false
    end
    return config_helpers.show_config_picker_for_session(session, category)
  end

  function backend.show_command_palette(target_pane)
    local session = get_session(target_pane)
    if not session then
      return false
    end
    return config_helpers.show_command_palette_for_session(session, function(prompt)
      backend.paste_and_submit(target_pane, prompt, { "C-m" }, {})
    end)
  end

  function backend.show_tool_timeline(target_pane)
    local session = get_session(target_pane)
    if not session then
      return false
    end
    return actions_helpers.show_tool_timeline_for_session(session)
  end

  function backend.show_tool_timeline_entry(target_pane, tool_call_id)
    local session = get_session(target_pane)
    local entry = session and conversation_helpers.tool_timeline_entry_for_call(session, tool_call_id) or nil
    if not entry then
      return false
    end
    actions_helpers.open_tool_timeline_buffer(session, entry)
    return true
  end

  function backend.get_tool_timeline_entry(target_pane, tool_call_id)
    local session = get_session(target_pane)
    local entry = session and conversation_helpers.tool_timeline_entry_for_call(session, tool_call_id) or nil
    return entry and vim.deepcopy(entry) or nil
  end

  function backend.get_conversation_timeline(target_pane)
    local session = get_session(target_pane)
    return session and vim.deepcopy(session.conversation_timeline or {}) or {}
  end

  function backend.toggle_conversation_pin(target_pane, item_id, pinned)
    local session = get_session(target_pane)
    local item = session and conversation_helpers.conversation_item_for_id(session, item_id) or nil
    if not item then
      return nil
    end
    if pinned == nil then
      pinned = not item.pinned
    end
    item.pinned = pinned == true
    conversation_helpers.sync_tool_pin_state(session, item)
    state_helpers.sync_runtime_live_state(session)
    return item.pinned
  end

  function backend.show_resource_browser(target_pane)
    local session = get_session(target_pane)
    if not session then
      return false
    end
    return actions_helpers.show_resource_browser_for_session(session)
  end

  function backend.show_capabilities(target_pane)
    local session = get_session(target_pane)
    if not session then
      return false
    end
    return actions_helpers.show_capabilities_for_session(session)
  end

  function backend.show_doctor(target_pane)
    local session = get_session(target_pane)
    if not session then
      return false
    end
    return actions_helpers.show_doctor_for_session(session)
  end

  function backend.show_context_budget(target_pane)
    local session = get_session(target_pane)
    if not session then
      return false
    end
    return actions_helpers.show_context_budget_for_session(session)
  end

  function backend.show_tool_review(target_pane)
    local session = get_session(target_pane)
    if not session then
      return false
    end
    return actions_helpers.show_tool_review_for_session(session)
  end

  function backend.list_sessions(target_pane, on_done, opts)
    local session = get_session(target_pane)
    if not session or not session.client then
      if on_done then
        vim.schedule(function()
          on_done(nil, {
            code = -32602,
            message = "ACP session is not ready",
          })
        end)
      end
      return false
    end

    if not session.client:supports_session_list() then
      if on_done then
        vim.schedule(function()
          on_done(nil, {
            code = -32602,
            message = "ACP agent does not support session/list",
          })
        end)
      end
      return false
    end

    local params = {}
    if not (opts and opts.all_cwds == true) then
      params.cwd = session.cwd
    end

    host_helpers.list_all_sessions_for_client(session.client, params, function(items, err)
      if err then
        if on_done then
          vim.schedule(function()
            on_done(nil, err)
          end)
        end
        return
      end

      local sessions_out = {}
      local by_id = {}
      for _, item in ipairs(items or {}) do
        local normalized = state_helpers.normalize_session_info(item.sessionId, item)
        sessions_out[#sessions_out + 1] = normalized
        by_id[normalized.sessionId] = normalized
      end

      if session.session_info and session.session_info.sessionId and session.session_info.sessionId ~= "" then
        local existing = by_id[session.session_info.sessionId]
        if existing then
          by_id[session.session_info.sessionId] = state_helpers.normalize_session_info(existing.sessionId, session.session_info, existing)
          for idx, item in ipairs(sessions_out) do
            if item.sessionId == existing.sessionId then
              sessions_out[idx] = by_id[existing.sessionId]
              break
            end
          end
        else
          sessions_out[#sessions_out + 1] = state_helpers.normalize_session_info(session.session_info.sessionId, session.session_info)
        end
      end

      table.sort(sessions_out, function(a, b)
        local a_updated = tostring(a.updatedAt or "")
        local b_updated = tostring(b.updatedAt or "")
        if a_updated ~= b_updated then
          return a_updated > b_updated
        end
        return tostring(a.title or a.sessionId or "") < tostring(b.title or b.sessionId or "")
      end)

      if on_done then
        vim.schedule(function()
          on_done(sessions_out, nil)
        end)
      end
    end)
    return true
  end

  function backend.capture_native_session(target_pane, native_session, on_done)
    local session = get_session(target_pane)
    if not session or not session.client then
      if on_done then
        vim.schedule(function()
          on_done(nil, {
            code = -32602,
            message = "ACP session is not ready",
          })
        end)
      end
      return false
    end

    if type(native_session) ~= "table" or not native_session.sessionId or native_session.sessionId == "" then
      if on_done then
        vim.schedule(function()
          on_done(nil, {
            code = -32602,
            message = "Missing ACP sessionId",
          })
        end)
      end
      return false
    end

    if not session.client:supports_session_load() then
      if on_done then
        vim.schedule(function()
          on_done(nil, {
            code = -32602,
            message = "ACP agent does not support session/load",
          })
        end)
      end
      return false
    end

    host_helpers.capture_native_session_for_session(
      session,
      state_helpers.normalize_session_info(native_session.sessionId, native_session),
      on_done
    )
    return true
  end

  function backend.capture_pane(pane_id, on_output)
    local session = get_session(pane_id)
    local text = ""
    if session and vim.fn.filereadable(session.transcript_path) == 1 then
      local ok, transcript_lines = pcall(vim.fn.readfile, session.transcript_path)
      if ok and transcript_lines then
        text = table.concat(transcript_lines, "\n")
      end
    end
    if on_output then
      vim.schedule(function()
        pcall(on_output, text)
      end)
    end
    return true
  end

  function backend.capture_pane_sync(pane_id)
    local session = get_session(pane_id)
    if not session or vim.fn.filereadable(session.transcript_path) == 0 then
      return ""
    end
    local ok, transcript_lines = pcall(vim.fn.readfile, session.transcript_path)
    if not ok or not transcript_lines then
      return ""
    end
    return table.concat(transcript_lines, "\n")
  end

  function backend.clear_transcript(pane_id, replacement_text)
    local session = get_session(pane_id)
    if not session then
      return false
    end
    return state_helpers.clear_session_transcript(session, replacement_text)
  end

  return backend
end

M.new = create_backend

return M
