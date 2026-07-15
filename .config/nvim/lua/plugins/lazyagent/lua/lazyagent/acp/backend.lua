
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
local backend_cancellation = require("lazyagent.acp.backend.cancellation")
local PromptQueue = require("lazyagent.acp.prompt_queue")
local ThreadExport = require("lazyagent.acp.thread_export")
local Notifications = require("lazyagent.acp.notifications")
local backend_host = require("lazyagent.acp.backend.host")
local ThreadStore = require("lazyagent.acp.thread_store")
local WorkspaceSnapshot = require("lazyagent.acp.workspace_snapshot")
local TurnJournal = require("lazyagent.acp.turn_journal")
local Watch = require("lazyagent.watch")
local BlobStore = require("lazyagent.acp.blob_store")
local ChangeReview = require("lazyagent.acp.change_review")
local ChangeApply = require("lazyagent.acp.change_apply")
local Follow = require("lazyagent.acp.follow")

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

local function table_count(value)
  local count = 0
  for _ in pairs(type(value) == "table" and value or {}) do
    count = count + 1
  end
  return count
end

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

local function sync_thread_record(session, changes)
  if not session or not session.thread_store or not session.thread_id then
    return nil
  end
  local opts = {}
  if changes and changes.process_id == vim.NIL and session.client and session.client.pid then
    opts.expected_process_id = session.client.pid
  end
  local updated, err = session.thread_store:update(session.thread_id, changes or {}, opts)
  if not updated then
    if type(err) == "table" and err.code == "stale_process" then
      return nil, err
    end
    session.thread_store_error = tostring(err)
    return nil, err
  end
  session.thread_store_error = nil
  session.thread_record = updated
  return updated
end

local function sync_thread_view(session)
  local view = session and session.view or nil
  if not view or type(view.capture_thread_view) ~= "function" then
    return nil
  end
  local view_state = view.capture_thread_view(session.pane_id, session)
  if type(view_state) ~= "table" then
    return nil
  end
  return sync_thread_record(session, { view_state = view_state })
end

local record_turn_event
local maybe_follow_agent

local function record_turn_baseline(session)
  if not session or not session.thread_id then
    return nil
  end
  local captured, snapshot = pcall(WorkspaceSnapshot.capture, session.root_dir or session.cwd, {
    blob_store = session.blob_store,
  })
  if not captured then
    session.workspace_snapshot_error = tostring(snapshot)
    return nil
  end
  session.workspace_snapshot_error = nil
  local journal, turn = TurnJournal.start(
    (session.thread_record and session.thread_record.change_journal) or {},
    session.thread_id,
    snapshot
  )
  local updated = sync_thread_record(session, { change_journal = journal })
  if updated then
    session.current_change_turn_id = turn.turn_id
    if session.turn_watch_handle then
      Watch.remove(session.turn_watch_handle)
    end
    local watched_turn_id = turn.turn_id
    session.turn_watch_handle = Watch.add(snapshot.root .. "/.lazyagent-turn-watch", function(path)
      if session.current_change_turn_id == watched_turn_id then
        record_turn_event(session, "file", {
          path = path,
          operation = "observed",
          source = "filesystem_watcher",
        })
      end
    end, { debounce_ms = 75 })
    return turn
  end
  return nil
end

record_turn_event = function(session, kind, event)
  if not session or not session.current_change_turn_id or not session.thread_record then
    return nil
  end
  local journal, turn = TurnJournal.record(
    session.thread_record.change_journal,
    session.current_change_turn_id,
    kind,
    event
  )
  if not journal then
    return nil
  end
  local recorded = sync_thread_record(session, { change_journal = journal }) and turn or nil
  if maybe_follow_agent then
    maybe_follow_agent(session, event)
  end
  return recorded
end

maybe_follow_agent = function(session, event)
  if not session or session.follow_agent ~= true then
    return nil
  end
  local target = Follow.resolve(session, event)
  if not target or target.key == session.follow_agent_last_target then
    return nil
  end
  session.follow_agent_last_target = target.key
  vim.schedule(function()
    if get_session(session.pane_id) == session and session.follow_agent == true then
      util.open_in_normal_win(target.path, { line = target.line })
    end
  end)
  return target
end

local function finish_change_turn(session, completion_state)
  if not session or not session.current_change_turn_id or not session.thread_record then
    return nil
  end
  if session.turn_watch_handle then
    Watch.remove(session.turn_watch_handle)
    session.turn_watch_handle = nil
  end

  local turn_id = session.current_change_turn_id
  local journal = session.thread_record.change_journal or {}
  local active_turn = TurnJournal.get(journal, turn_id)
  if not active_turn then
    session.current_change_turn_id = nil
    return nil
  end

  local captured, final_snapshot = pcall(
    WorkspaceSnapshot.capture,
    (active_turn.baseline and active_turn.baseline.root) or session.root_dir or session.cwd,
    { blob_store = session.blob_store }
  )
  local capture_error = nil
  local changes = {}
  if captured then
    changes = WorkspaceSnapshot.diff(active_turn.baseline, final_snapshot)
  else
    capture_error = tostring(final_snapshot)
    final_snapshot = nil
  end
  local finished_at = final_snapshot and final_snapshot.captured_at or os.date("!%Y-%m-%dT%H:%M:%SZ")
  local finished_journal, finished_turn = TurnJournal.finish(journal, turn_id, {
    state = completion_state,
    finished_at = finished_at,
    final_snapshot = final_snapshot,
    changes = changes,
    capture_error = capture_error,
  })
  session.current_change_turn_id = nil
  if not finished_journal then
    return nil
  end
  return sync_thread_record(session, { change_journal = finished_journal }) and finished_turn or nil
end

local function path_in_session_workspace(session, path)
  path = vim.fn.fnamemodify(tostring(path or ""), ":p"):gsub("/$", "")
  local roots = {}
  if session.root_dir or session.cwd then
    roots[#roots + 1] = session.root_dir or session.cwd
  end
  if session.cwd and session.cwd ~= session.root_dir then
    roots[#roots + 1] = session.cwd
  end
  vim.list_extend(roots, session.additional_directories or {})
  for _, root in ipairs(roots) do
    root = vim.fn.fnamemodify(tostring(root or ""), ":p"):gsub("/$", "")
    if path == root or path:sub(1, #root + 1) == root .. "/" then
      return true
    end
  end
  return false
end

local function single_active_tool_id(session)
  local found = nil
  for tool_id in pairs(session.tool_calls or {}) do
    if found then
      return nil
    end
    found = tool_id
  end
  return found
end

local buffer_event_group = vim.api.nvim_create_augroup("LazyAgentACPTurnJournal", { clear = true })
vim.api.nvim_create_autocmd("BufWritePost", {
  group = buffer_event_group,
  callback = function(args)
    local path = args.file ~= "" and args.file or vim.api.nvim_buf_get_name(args.buf)
    for _, session in pairs(sessions) do
      local turn_active = session.current_change_turn_id
        and (session.busy or session.pending_brain_turn or next(session.tool_calls or {}) ~= nil)
      if turn_active and path_in_session_workspace(session, path) then
        record_turn_event(session, "buffer", {
          event = "BufWritePost",
          path = vim.fn.fnamemodify(path, ":p"),
          bufnr = args.buf,
          source = "nvim_buffer",
          tool_call_id = single_active_tool_id(session),
        })
      end
    end
  end,
})

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
  sync_thread = sync_thread_record,
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
  sync_thread = sync_thread_record,
  record_turn_event = record_turn_event,
})

local function create_backend(default_view)
  local backend = {}
  local thread_store = ThreadStore.new({ dir = cache_logic.get_cache_dir() .. "/acp/threads" })
  local blob_store = BlobStore.new({ dir = cache_logic.get_cache_dir() .. "/acp/blobs" })
  local change_apply = ChangeApply.new({
    read_blob = function(ref)
      return blob_store:get(ref)
    end,
    put_blob = function(data)
      return blob_store:put(data)
    end,
  })
  local change_review = ChangeReview.new({
    read_blob = function(ref)
      return blob_store:get(ref)
    end,
    decide = function(thread, turn, indices, decision)
      return backend.decide_thread_changes(thread.thread_id, turn.turn_id, indices, decision)
    end,
    hunks = function(thread, turn, change_index)
      return backend.get_thread_change_hunks(thread.thread_id, turn.turn_id, change_index)
    end,
    decide_hunk = function(thread, turn, change_index, hunk_index, decision)
      return backend.decide_thread_hunk(thread.thread_id, turn.turn_id, change_index, hunk_index, decision)
    end,
    checkpoint = function(thread, turn, action)
      return backend.apply_thread_checkpoint(thread.thread_id, turn.turn_id, action)
    end,
    branch = function(thread, turn)
      return backend.branch_thread_checkpoint(thread.thread_id, turn.turn_id)
    end,
  })

  complete_pending_turn = function(session)
    local pending = session and session.pending_brain_turn or nil
    if not pending then
      return false
    end
    session.pending_brain_turn = nil
    finish_change_turn(session, "completed")
    util.fire_event("AssistantResponse", { agent_name = session.agent_name, result = pending.result })
    util.fire_event("TurnDone", { agent_name = session.agent_name, result = pending.result })
    actions_helpers.maybe_call_mcp_tool("notify_done", { agent_name = session.agent_name })
    Notifications.emit(((state.opts or {}).acp or {}).notifications, "completion", {
      agent_name = session.agent_name,
      message = "Response completed",
    })
    config_helpers.maybe_save_turn_to_brain(session, pending.prompt, pending.start_seq)
    return true
  end

  local function session_view(session)
    return (session and session.view) or default_view
  end

  local function finalize_cancelled_tools(session)
    return backend_cancellation.finalize_tools(session, {
      merge_tool_update = conversation_helpers.merge_tool_update,
      append_block = conversation_helpers.append_block,
      tool_heading = conversation_helpers.tool_heading,
      extract_tool_paths = actions_helpers.extract_tool_paths,
    })
  end

  function backend._drain_prompt_queue(pane_id)
    local session = get_session(pane_id)
    if not session or session.failed or session.busy or session.preparing_prompt or not session.ready or not session.client then
      return false
    end

    local queued_prompt = PromptQueue.pop(session)
    if not queued_prompt then
      return false
    end
    local prompt = queued_prompt.text

    session.preparing_prompt = true
    config_helpers.maybe_apply_auto_switch(session, prompt, function()
      if next(session.tool_calls or {}) == nil then
        complete_pending_turn(session)
      end
      if session.cancel_requested == true then
        session.cancel_requested = false
        session.preparing_prompt = false
        conversation_helpers.append_block(session, "System", "Prompt cancelled before send")
        pcall(function()
          require("lazyagent.logic.status").set_waiting(session.agent_name, "Cancelled")
        end)
        if #session.prompt_queue > 0 then
          vim.schedule(function()
            backend._drain_prompt_queue(pane_id)
          end)
        end
        return
      end
      session.preparing_prompt = false
      record_turn_baseline(session)
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
        local cancel_requested = session.cancel_requested == true
        session.cancel_requested = false
        conversation_helpers.close_stream(session)

        if err then
          session.pending_brain_turn = nil
          if cancel_requested then
            finalize_cancelled_tools(session)
          end
          finish_change_turn(session, cancel_requested and "cancelled" or "failed")
          if cancel_requested then
            conversation_helpers.append_block(session, "System", "Turn cancelled")
            if #session.prompt_queue > 0 then
              vim.schedule(function()
                backend._drain_prompt_queue(pane_id)
              end)
            end
          else
            conversation_helpers.append_block(session, "Error", err.message or tostring(err))
            pcall(function()
              require("lazyagent.logic.status").set_waiting(session.agent_name, "ACP error")
            end)
            session.prompt_queue = {}
          end
          return
        end

        if session.pending_switch_history then
          state_helpers.clear_pending_switch_history(session)
        end

        local stop_reason = result and result.stopReason or nil
        if cancel_requested or stop_reason == "cancelled" then
          session.pending_brain_turn = nil
          finalize_cancelled_tools(session)
          finish_change_turn(session, "cancelled")
          conversation_helpers.append_block(session, "System", "Turn cancelled")
          util.fire_event("TurnDone", {
            agent_name = session.agent_name,
            result = result,
            cancelled = true,
          })
          actions_helpers.maybe_call_mcp_tool("notify_done", {
            agent_name = session.agent_name,
            cancelled = true,
          })
          pcall(function()
            require("lazyagent.logic.status").set_waiting(session.agent_name, "Cancelled")
          end)
          if #session.prompt_queue > 0 then
            backend._drain_prompt_queue(pane_id)
          end
          return
        end
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

    local existing_thread = nil
    if acp.thread_id and acp.thread_id ~= "" then
      local thread_err
      existing_thread, thread_err = thread_store:get(acp.thread_id)
      if not existing_thread then
        vim.schedule(function()
          vim.notify("LazyAgent ACP thread open failed: " .. tostring(thread_err or acp.thread_id), vim.log.levels.ERROR)
        end)
        if on_split then
          vim.schedule(function()
            on_split(nil)
          end)
        end
        return
      end
      local provider_id = tostring(acp.provider_id or acp.agent_name)
      if existing_thread.provider_id ~= provider_id then
        vim.schedule(function()
          vim.notify(
            string.format("LazyAgent ACP thread provider mismatch: expected %s, got %s", existing_thread.provider_id, provider_id),
            vim.log.levels.ERROR
          )
        end)
        if on_split then
          vim.schedule(function()
            on_split(nil)
          end)
        end
        return
      end
    end

    local transcript_path = existing_thread and existing_thread.transcript_path ~= "" and existing_thread.transcript_path
      or state_helpers.build_transcript_path(acp.agent_name, acp.source_bufnr)
    local carryover_lines = nil
    if existing_thread and vim.fn.filereadable(transcript_path) == 1 then
      carryover_lines = state_helpers.read_path_lines(transcript_path)
    end
    local initial_text = conversation_helpers.render_section_block("System", "Connecting ACP session for " .. acp.agent_name .. "...")
    if not existing_thread then
      state_helpers.write_transcript(transcript_path, "", "w")
    end
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
        prompt_queue_seq = 0,
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
        additional_directories = vim.deepcopy(acp.additional_directories or {}),
        mcp_url = acp.mcp_url,
        session_bootstrap = vim.deepcopy(acp.session_bootstrap or (existing_thread and existing_thread.native_session_id and {
          session_mode = "auto",
          session_id = existing_thread.native_session_id,
        }) or nil),
        thread_carryover = existing_thread and {
          provider_from = existing_thread.provider_id,
          carryover_label = "the previously opened LazyAgent thread",
          transcript_lines = vim.deepcopy(carryover_lines or {}),
          transcript_path = transcript_path,
          conversation_timeline = {},
          tool_timeline = {},
        } or nil,
        auto_permission = acp.auto_permission,
        default_mode = acp.default_mode or (existing_thread and existing_thread.mode) or nil,
        initial_model = acp.initial_model or (existing_thread and existing_thread.model) or nil,
        initial_config_snapshot = existing_thread and vim.deepcopy(existing_thread.config or {}) or {},
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
        protocol_events = {},
        auth_methods = {},
        view = view,
        view_state = view_state or {},
        provider_id = acp.provider_id or acp.agent_name,
        thread_store = thread_store,
        blob_store = blob_store,
        follow_agent = existing_thread
            and existing_thread.metadata
            and existing_thread.metadata.follow_agent == true
          or acp.follow_agent == true,
        thread_record = existing_thread and vim.deepcopy(existing_thread) or nil,
      }
      local session = sessions[pane_id]
      local thread_attributes = {
        cwd = session.cwd,
        additional_directories = session.additional_directories,
        status = "active",
        transcript_path = transcript_path,
        model = session.initial_model,
        mode = session.default_mode,
        config = vim.deepcopy(session.manual_config_overrides or {}),
      }
      local thread, thread_err
      if existing_thread then
        thread, thread_err = thread_store:open(existing_thread.thread_id, thread_attributes)
      else
        thread_attributes.provider_id = session.provider_id
        thread_attributes.title = acp.thread_title or acp.agent_name
        thread, thread_err = thread_store:create(thread_attributes)
      end
      if thread then
        session.thread_id = thread.thread_id
        session.thread_record = thread
      else
        session.thread_store_error = tostring(thread_err)
      end
      conversation_helpers.new_conversation_item(
        session,
        "System",
        "Connecting ACP session for " .. acp.agent_name .. "..."
      )

      if type(view.on_session_created) == "function" then
        view.on_session_created(session)
      end
      if existing_thread
        and type(existing_thread.view_state) == "table"
        and type(view.restore_thread_view) == "function"
      then
        view.restore_thread_view(pane_id, existing_thread.view_state, session)
      end
      host_helpers.start_client(session, {
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

  function backend.list_threads(opts)
    return thread_store:list(opts)
  end

  function backend.get_thread(thread_id)
    return thread_store:get(thread_id)
  end

  function backend.show_thread_changes(thread_id)
    local thread, err = thread_store:get(thread_id)
    if not thread then
      return nil, err or ("thread not found: " .. tostring(thread_id))
    end
    return change_review.open(thread)
  end

  function backend.toggle_follow_agent(pane_id)
    local session = get_session(pane_id)
    if not session then
      return nil, "ACP session is not active"
    end
    session.follow_agent = session.follow_agent ~= true
    session.follow_agent_last_target = nil
    local metadata = vim.deepcopy((session.thread_record and session.thread_record.metadata) or {})
    metadata.follow_agent = session.follow_agent
    sync_thread_record(session, { metadata = metadata })
    if session.follow_agent then
      local tool = session.tool_timeline and session.tool_timeline[#session.tool_timeline] or nil
      if tool then
        maybe_follow_agent(session, { paths = tool.paths })
      else
        local turns = session.thread_record and session.thread_record.change_journal
          and session.thread_record.change_journal.turns or {}
        local turn = turns[#turns]
        local change = turn and turn.changes and turn.changes[#turn.changes] or nil
        if change then
          maybe_follow_agent(session, { path = change.path })
        end
      end
    end
    return session.follow_agent
  end

  function backend.decide_thread_changes(thread_id, turn_id, indices, decision)
    local thread, err = thread_store:get(thread_id)
    if not thread then
      return nil, err
    end
    local turn = TurnJournal.get(thread.change_journal, turn_id)
    if not turn then
      return nil, "turn not found: " .. tostring(turn_id)
    end
    local applications = nil
    if decision == "rejected" then
      local selected = {}
      for _, index in ipairs(indices or {}) do
        if not turn.changes[index] then
          return nil, "change not found: " .. tostring(index)
        end
        if turn.changes[index].decision then
          return nil, "change already decided: " .. tostring(index)
        end
        selected[#selected + 1] = turn.changes[index]
      end
      local root = turn.baseline and turn.baseline.root or thread.cwd
      local apply_err
      applications, apply_err = change_apply.reject_all(selected, root)
      if not applications then
        return nil, apply_err
      end
      local root_prefix = vim.fn.fnamemodify(root, ":p"):gsub("/$", "")
      for _, change in ipairs(selected) do
        state_helpers.reload_loaded_buffers_for_path(root_prefix .. "/" .. change.path)
        if change.previous_path then
          state_helpers.reload_loaded_buffers_for_path(root_prefix .. "/" .. change.previous_path)
        end
      end
    elseif decision ~= "kept" then
      return nil, "unsupported change decision: " .. tostring(decision)
    else
      for _, index in ipairs(indices or {}) do
        if not turn.changes[index] then
          return nil, "change not found: " .. tostring(index)
        end
        if turn.changes[index].decision then
          return nil, "change already decided: " .. tostring(index)
        end
      end
    end
    local journal, decided = TurnJournal.decide(
      thread.change_journal,
      turn_id,
      indices,
      decision,
      os.date("!%Y-%m-%dT%H:%M:%SZ"),
      applications
    )
    if not journal then
      return nil, decided
    end
    local updated, update_err = thread_store:update(thread_id, { change_journal = journal })
    if not updated then
      return nil, update_err
    end
    for _, session in pairs(sessions) do
      if session.thread_id == thread_id then
        session.thread_record = vim.deepcopy(updated)
      end
    end
    return decided
  end

  function backend.get_thread_change_hunks(thread_id, turn_id, change_index)
    local thread, err = thread_store:get(thread_id)
    if not thread then
      return nil, err
    end
    local turn = TurnJournal.get(thread.change_journal, turn_id)
    local change = turn and turn.changes and turn.changes[change_index] or nil
    if not change then
      return nil, "change not found: " .. tostring(change_index)
    end
    local hunks, hunk_err = change_apply.hunks(change)
    if not hunks then
      return nil, hunk_err
    end
    local decisions = {}
    for _, hunk in ipairs(change.hunks or {}) do
      decisions[hunk.index] = hunk
    end
    for _, hunk in ipairs(hunks) do
      if decisions[hunk.index] then
        hunk.decision = decisions[hunk.index].decision
        hunk.decided_at = decisions[hunk.index].decided_at
      end
    end
    return hunks
  end

  function backend.decide_thread_hunk(thread_id, turn_id, change_index, hunk_index, decision)
    if decision ~= "kept" and decision ~= "rejected" then
      return nil, "unsupported hunk decision: " .. tostring(decision)
    end
    local thread, err = thread_store:get(thread_id)
    if not thread then
      return nil, err
    end
    local turn = TurnJournal.get(thread.change_journal, turn_id)
    local change = turn and turn.changes and turn.changes[change_index] or nil
    if not change then
      return nil, "change not found: " .. tostring(change_index)
    end
    if change.decision then
      return nil, "file change already decided"
    end
    local hunks, hunk_err = change_apply.hunks(change)
    if not hunks then
      return nil, hunk_err
    end
    local current_hunk = change.hunks and change.hunks[hunk_index] or nil
    if current_hunk and current_hunk.decision then
      return nil, "hunk already decided: " .. tostring(hunk_index)
    end
    local review_blob = nil
    if decision == "rejected" then
      review_blob, hunk_err = change_apply.reject_hunks(change, turn.baseline.root or thread.cwd, { hunk_index })
      if not review_blob then
        return nil, hunk_err
      end
      state_helpers.reload_loaded_buffers_for_path(
        vim.fn.fnamemodify(turn.baseline.root or thread.cwd, ":p"):gsub("/$", "") .. "/" .. change.path
      )
    end
    local journal, decided = TurnJournal.decide_hunk(
      thread.change_journal,
      turn_id,
      change_index,
      hunks,
      hunk_index,
      decision,
      review_blob,
      os.date("!%Y-%m-%dT%H:%M:%SZ")
    )
    if not journal then
      return nil, decided
    end
    local updated, update_err = thread_store:update(thread_id, { change_journal = journal })
    if not updated then
      return nil, update_err
    end
    for _, session in pairs(sessions) do
      if session.thread_id == thread_id then
        session.thread_record = vim.deepcopy(updated)
      end
    end
    return decided
  end

  function backend.apply_thread_checkpoint(thread_id, turn_id, action)
    local thread, err = thread_store:get(thread_id)
    if not thread then
      return nil, err
    end
    local turn = TurnJournal.get(thread.change_journal, turn_id)
    if not turn then
      return nil, "turn not found: " .. tostring(turn_id)
    end
    local changes = turn.changes or {}
    if #changes == 0 then
      return nil, "checkpoint has no file changes"
    end
    local root = turn.baseline and turn.baseline.root or thread.cwd
    local target_changes = changes
    if action == "redo" then
      if not thread.checkpoint or thread.checkpoint.turn_id ~= turn_id or thread.checkpoint.state ~= "restored" then
        return nil, "checkpoint must be restored before redo"
      end
      target_changes = ChangeApply.inverse_changes(changes)
    elseif action ~= "restore" then
      return nil, "unsupported checkpoint action: " .. tostring(action)
    end
    local applied, apply_err = change_apply.reject_all(target_changes, root)
    if not applied then
      return nil, apply_err
    end
    local checkpoint = {
      turn_id = turn_id,
      state = action == "redo" and "redone" or "restored",
      updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }
    local updated, update_err = thread_store:update(thread_id, { checkpoint = checkpoint })
    if not updated then
      return nil, update_err
    end
    local root_prefix = vim.fn.fnamemodify(root, ":p"):gsub("/$", "")
    for _, change in ipairs(changes) do
      state_helpers.reload_loaded_buffers_for_path(root_prefix .. "/" .. change.path)
      if change.previous_path then
        state_helpers.reload_loaded_buffers_for_path(root_prefix .. "/" .. change.previous_path)
      end
    end
    for _, session in pairs(sessions) do
      if session.thread_id == thread_id then
        session.thread_record = vim.deepcopy(updated)
      end
    end
    return updated
  end

  function backend.branch_thread_checkpoint(thread_id, turn_id)
    local parent, err = thread_store:get(thread_id)
    if not parent then
      return nil, err
    end
    local turn = TurnJournal.get(parent.change_journal, turn_id)
    if not turn then
      return nil, "turn not found: " .. tostring(turn_id)
    end
    local branch, create_err = thread_store:create({
      provider_id = parent.provider_id,
      cwd = parent.cwd,
      additional_directories = parent.additional_directories,
      title = parent.title .. " · branch " .. tostring(turn_id):match("[^:]+$"),
      status = "closed",
      model = parent.model,
      mode = parent.mode,
      config = parent.config,
      checkpoint = {
        parent_thread_id = parent.thread_id,
        parent_turn_id = turn_id,
        state = "client_local_branch",
      },
      metadata = {
        client_local_branch = true,
        parent_thread_id = parent.thread_id,
        parent_turn_id = turn_id,
      },
    })
    if not branch then
      return nil, create_err
    end
    if parent.transcript_path and parent.transcript_path ~= "" and vim.fn.filereadable(parent.transcript_path) == 1 then
      local branch_dir = cache_logic.get_cache_dir() .. "/acp/branches"
      vim.fn.mkdir(branch_dir, "p")
      local branch_path = branch_dir .. "/" .. branch.thread_id .. ".log"
      local ok_read, lines = pcall(vim.fn.readfile, parent.transcript_path, "b")
      local ok_write, write_result = false, nil
      if ok_read then
        ok_write, write_result = pcall(vim.fn.writefile, lines, branch_path, "b")
      end
      if not ok_read or not ok_write or write_result ~= 0 then
        thread_store:delete(branch.thread_id)
        return nil, "failed to copy branch transcript"
      end
      local updated, update_err = thread_store:update(branch.thread_id, { transcript_path = branch_path })
      if not updated then
        pcall(vim.fn.delete, branch_path)
        thread_store:delete(branch.thread_id)
        return nil, update_err
      end
      branch = updated
    end
    return branch
  end

  function backend.create_thread(attributes)
    return thread_store:create(attributes)
  end

  function backend.archive_thread(thread_id)
    return thread_store:archive(thread_id)
  end

  function backend.restore_thread(thread_id)
    return thread_store:restore(thread_id)
  end

  function backend.rename_thread(thread_id, title)
    return thread_store:rename(thread_id, title)
  end

  function backend.delete_thread(thread_id)
    return thread_store:delete(thread_id)
  end

  function backend.import_native_session(pane_id, native_session)
    local session = get_session(pane_id)
    if not session then
      return nil, "ACP session is not active"
    end
    if type(native_session) ~= "table" or not native_session.sessionId or native_session.sessionId == "" then
      return nil, "native ACP sessionId is required"
    end
    local threads, list_err = thread_store:list({ include_archived = true })
    if not threads then
      return nil, list_err
    end
    for _, thread in ipairs(threads) do
      if thread.provider_id == session.provider_id and thread.native_session_id == native_session.sessionId then
        return thread, false
      end
    end
    local thread, err = thread_store:create({
      provider_id = session.provider_id,
      native_session_id = native_session.sessionId,
      cwd = native_session.cwd or session.cwd,
      additional_directories = session.additional_directories,
      title = native_session.title or native_session.summary or (session.provider_id .. " session"),
      status = "closed",
      metadata = {
        imported_from_native = true,
        native_summary = native_session.summary,
        native_updated_at = native_session.updatedAt,
      },
    })
    if not thread then
      return nil, err
    end
    return thread, true
  end

  function backend.update_thread(thread_id, changes)
    local updated, err = thread_store:update(thread_id, changes)
    if not updated then
      return nil, err
    end
    for _, session in pairs(sessions) do
      if session.thread_id == updated.thread_id then
        session.thread_record = vim.deepcopy(updated)
      end
    end
    return updated
  end

  function backend.set_thread_draft(thread_id, draft)
    return backend.update_thread(thread_id, { draft = tostring(draft or "") })
  end

  function backend.mark_thread_read(thread_id)
    return backend.update_thread(thread_id, { unread = false })
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
      acp_thread_id = session.thread_id,
      acp_provider_id = session.provider_id,
      acp_thread_store_error = session.thread_store_error,
      acp_workspace_snapshot_error = session.workspace_snapshot_error,
      acp_follow_agent = session.follow_agent == true,
      acp_resume_strategy = session.resume_strategy,
      acp_has_pending_carryover = session.pending_switch_history ~= nil,
      acp_thread_draft = session.thread_record and session.thread_record.draft or "",
      acp_thread_unread = session.thread_record and session.thread_record.unread == true or false,
      acp_session_info = vim.deepcopy(session.session_info or {}),
      acp_transcript_path = session.transcript_path,
      acp_agent_info = vim.deepcopy(session.agent_info or {}),
      acp_agent_capabilities = vim.deepcopy(session.agent_capabilities or {}),
      acp_session_capabilities = vim.deepcopy((session.agent_capabilities and session.agent_capabilities.sessionCapabilities) or {}),
      acp_model_catalog = vim.deepcopy(session.model_catalog or {}),
      acp_mode_catalog = vim.deepcopy(session.mode_catalog or {}),
      acp_usage_stats = vim.deepcopy(session.usage_stats or {}),
      acp_protocol_events = vim.deepcopy(session.protocol_events or {}),
      acp_auth_methods = vim.deepcopy(session.auth_methods or {}),
      acp_client_debug = session.client and session.client:debug_snapshot() or nil,
      acp_view_debug = session.view and type(session.view.debug_snapshot) == "function"
          and session.view.debug_snapshot()
        or nil,
      acp_view_timer_count = session.view_state and session.view_state.append_timer and 1 or 0,
      acp_terminal_count = table_count(session.terminals),
      acp_prompt_queue = PromptQueue.list(session),
      acp_transcript_debug = {
        owned = session.transcript_path ~= nil and session.transcript_path ~= "",
        readable = session.transcript_path ~= nil and vim.fn.filereadable(session.transcript_path) == 1,
        size = session.transcript_path and vim.fn.getfsize(session.transcript_path) or -1,
      },
      acp_ready = session.ready == true,
      acp_failed = session.failed == true,
      acp_busy = session.busy == true,
      acp_preparing_prompt = session.preparing_prompt == true,
      acp_supports_embedded_context = session.prompt_supports_embedded_context == true,
      acp_supports_image = session.prompt_supports_image == true,
      acp_supports_audio = session.prompt_supports_audio == true,
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

  function backend.get_debug_snapshot()
    local snapshot = {
      session_count = 0,
      session_view_snapshot_count = table_count(state.session_views),
      transcript_owner_count = 0,
      terminal_count = 0,
      child_process_count = 0,
      timer_count = 0,
      callback_count = 0,
      sessions = {},
      views = {},
    }
    local seen_views = {}

    for pane_id, session in pairs(sessions) do
      snapshot.session_count = snapshot.session_count + 1
      if session.transcript_path and session.transcript_path ~= "" then
        snapshot.transcript_owner_count = snapshot.transcript_owner_count + 1
      end
      snapshot.terminal_count = snapshot.terminal_count + table_count(session.terminals)
      if session.view_state and session.view_state.append_timer then
        snapshot.timer_count = snapshot.timer_count + 1
      end

      local client_debug = session.client and session.client:debug_snapshot() or nil
      if client_debug then
        if client_debug.process == true then
          snapshot.child_process_count = snapshot.child_process_count + 1
        end
        snapshot.timer_count = snapshot.timer_count
          + (tonumber(client_debug.callback_timers) or 0)
          + (tonumber(client_debug.stop_timer) or 0)
        snapshot.callback_count = snapshot.callback_count + (tonumber(client_debug.callbacks) or 0)
      end
      snapshot.sessions[tostring(pane_id)] = backend.get_runtime_snapshot(pane_id)

      local view = session.view
      if view and not seen_views[view] and type(view.debug_snapshot) == "function" then
        seen_views[view] = true
        local view_debug = view.debug_snapshot()
        snapshot.views[#snapshot.views + 1] = view_debug
        snapshot.timer_count = snapshot.timer_count + (tonumber(view_debug.active_timer_count) or 0)
      end
    end

    local fallback_view = default_view
    if fallback_view and not seen_views[fallback_view] and type(fallback_view.debug_snapshot) == "function" then
      local view_debug = fallback_view.debug_snapshot()
      snapshot.views[#snapshot.views + 1] = view_debug
      snapshot.timer_count = snapshot.timer_count + (tonumber(view_debug.active_timer_count) or 0)
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
          session.cancel_requested = session.busy == true or session.preparing_prompt == true
          host_helpers.release_all_terminals(session)
          session.client:cancel()
          conversation_helpers.append_block(session, "System", "Cancellation requested")
        end
        return true
      elseif normalized == "Up" then
        return backend.scroll_up(pane_id)
      elseif normalized == "Down" then
        return backend.scroll_down(pane_id)
      elseif normalized == "Escape" then
        if session.view and type(session.view.resume_follow) == "function" then
          local result = session.view.resume_follow(pane_id)
          vim.schedule(function()
            if get_session(pane_id) == session then
              sync_thread_view(session)
            end
          end)
          return result
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
      if session.current_change_turn_id then
        finish_change_turn(session, "interrupted")
      end
      state_helpers.clear_pending_switch_history(session)
      session.closing_intentionally = true
      host_helpers.release_all_terminals(session)
      local view = session_view(session)
      sync_thread_view(session)
      if view and type(view.kill_pane) == "function" then
        view.kill_pane(pane_id, session)
      end
      state_helpers.release_closing_session_memory(session)
      sync_thread_record(session, {
        status = "closed",
        process_id = vim.NIL,
      })
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
      sync_thread_view(session)
      return view.break_pane(pane_id, session)
    end
    return false
  end

  function backend.break_pane_sync(pane_id)
    local session = get_session(pane_id)
    local view = session_view(session)
    if view and type(view.break_pane_sync) == "function" then
      sync_thread_view(session)
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
      local result = view.scroll_up(pane_id, session)
      vim.defer_fn(function()
        if get_session(pane_id) == session then
          sync_thread_view(session)
        end
      end, 100)
      return result
    end
    return false
  end

  function backend.scroll_down(pane_id)
    local session = get_session(pane_id)
    local view = session_view(session)
    if view and type(view.scroll_down) == "function" then
      local result = view.scroll_down(pane_id, session)
      vim.defer_fn(function()
        if get_session(pane_id) == session then
          sync_thread_view(session)
        end
      end, 100)
      return result
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
    PromptQueue.push(session, prompt)
    backend._drain_prompt_queue(target_pane)
    return true
  end

  function backend.list_prompt_queue(target_pane)
    local session = get_session(target_pane)
    return session and PromptQueue.list(session) or nil
  end

  function backend.edit_prompt_queue(target_pane, id, text)
    local session = get_session(target_pane)
    if not session then return nil, "ACP session not found" end
    return PromptQueue.edit(session, id, text)
  end

  function backend.remove_prompt_queue(target_pane, id)
    local session = get_session(target_pane)
    if not session then return nil, "ACP session not found" end
    return PromptQueue.remove(session, id)
  end

  function backend.move_prompt_queue(target_pane, id, delta)
    local session = get_session(target_pane)
    if not session then return nil, "ACP session not found" end
    return PromptQueue.move(session, id, delta)
  end

  function backend.send_prompt_now(target_pane, id)
    local session = get_session(target_pane)
    if not session then return nil, "ACP session not found" end
    local item, promote_err = PromptQueue.promote(session, id)
    if not item then return nil, promote_err end
    if session.busy == true or session.preparing_prompt == true then
      session.cancel_requested = true
      host_helpers.release_all_terminals(session)
      session.client:cancel()
      conversation_helpers.append_block(
        session,
        "System",
        "Send Now: cancelling the current ACP turn before sending queued prompt " .. item.id
      )
      return item, "cancel-and-send"
    end
    backend._drain_prompt_queue(target_pane)
    return item, "sent"
  end

  function backend.show_prompt_queue(target_pane)
    local session = get_session(target_pane)
    if not session then return false end
    local items = PromptQueue.list(session)
    if #items == 0 then
      vim.notify("LazyAgent ACP prompt queue is empty", vim.log.levels.INFO)
      return true
    end
    vim.ui.select(items, {
      prompt = "Queued ACP prompts:",
      format_item = function(item)
        return string.format("%s  %s", item.id, tostring(item.text):gsub("%s+", " "):sub(1, 100))
      end,
    }, function(item)
      if not item then return end
      local actions = { "Edit", "Remove", "Move up", "Move down", "Send Now (cancel current turn)" }
      vim.ui.select(actions, { prompt = "Queue action for " .. item.id .. ":" }, function(action)
        if action == "Edit" then
          vim.ui.input({ prompt = "Edit queued prompt: ", default = item.text }, function(value)
            if value then backend.edit_prompt_queue(target_pane, item.id, value) end
          end)
        elseif action == "Remove" then
          backend.remove_prompt_queue(target_pane, item.id)
        elseif action == "Move up" then
          backend.move_prompt_queue(target_pane, item.id, -1)
        elseif action == "Move down" then
          backend.move_prompt_queue(target_pane, item.id, 1)
        elseif action == "Send Now (cancel current turn)" then
          backend.send_prompt_now(target_pane, item.id)
        end
      end)
    end)
    return true
  end

  function backend.export_thread_markdown(target_pane, path)
    local session = get_session(target_pane)
    if not session then return nil, "ACP session not found" end
    path = vim.fn.fnamemodify(path, ":p")
    local markdown = ThreadExport.render({
      title = session.thread_record and session.thread_record.title or session.agent_name,
      provider_id = session.provider_id,
      cwd = session.root_dir or session.cwd,
      thread_id = session.thread_id,
      conversation = session.conversation_timeline,
      tools = session.tool_timeline,
    })
    local parent_ok, parent_err = state_helpers.ensure_parent_dir(path)
    if not parent_ok then return nil, parent_err end
    local ok, write_err = pcall(vim.fn.writefile, vim.split(markdown, "\n", { plain = true }), path, "b")
    if not ok then return nil, write_err end
    return path
  end

  function backend.show_thread_export(target_pane)
    local session = get_session(target_pane)
    if not session then return false end
    local title = sanitize_filename_component(session.thread_record and session.thread_record.title or session.agent_name)
    local default_path = (session.root_dir or session.cwd) .. "/" .. title .. "-thread.md"
    vim.ui.input({ prompt = "Export ACP thread Markdown: ", default = default_path }, function(path)
      if not path or path == "" then return end
      local exported, export_err = backend.export_thread_markdown(target_pane, path)
      if exported then
        vim.notify("Exported ACP thread to " .. exported, vim.log.levels.INFO)
      else
        vim.notify("LazyAgent ACP export failed: " .. tostring(export_err), vim.log.levels.ERROR)
      end
    end)
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
