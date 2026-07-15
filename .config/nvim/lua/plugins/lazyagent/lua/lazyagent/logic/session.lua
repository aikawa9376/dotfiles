-- logic/session.lua
-- This module is responsible for managing agent sessions, including
-- starting, stopping, and toggling interactive sessions.
local M = {}

local state = require("lazyagent.logic.state")
local acp_logic = require("lazyagent.logic.acp")
local agent_logic = require("lazyagent.logic.agent")
local backend_logic = require("lazyagent.logic.backend")
local keymaps_logic = require("lazyagent.logic.keymaps")
local send_logic = require("lazyagent.logic.send")
local skills_logic = require("lazyagent.logic.skills")
local cache_logic = require("lazyagent.logic.cache")
local session_acp = require("lazyagent.logic.session.acp")
local session_conversation = require("lazyagent.logic.session.conversation")
local session_lifecycle = require("lazyagent.logic.session.lifecycle")
local session_runtime = require("lazyagent.logic.session.runtime")
local session_launch = require("lazyagent.logic.session.launch")
local session_actions = require("lazyagent.logic.session.actions")
local session_acp_actions = require("lazyagent.logic.session.acp_actions")
local session_threads = require("lazyagent.logic.session.threads")
local window = require("lazyagent.window")
local persistence = require("lazyagent.logic.persistence")
local util = require("lazyagent.util")

local function refresh_acp_command_visibility()
  pcall(function()
    require("lazyagent.commands.acp").refresh()
  end)
end

local function call_watch(method, ...)
  local ok_watch, watch = pcall(require, "lazyagent.watch")
  if not ok_watch or not watch then
    return false
  end
  local fn = watch[method]
  if type(fn) ~= "function" then
    return false
  end
  return pcall(fn, ...)
end

M.wait_for_idle_before_close = session_lifecycle.wait_for_idle_before_close

local launch = session_launch.setup({
  state = state,
  acp_logic = acp_logic,
  agent_logic = agent_logic,
  backend_logic = backend_logic,
  keymaps_logic = keymaps_logic,
  send_logic = send_logic,
  skills_logic = skills_logic,
  window = window,
  persistence = persistence,
  util = util,
  call_watch = call_watch,
  maybe_disable_watchers = session_lifecycle.maybe_disable_watchers,
  current_editor_session_name = session_acp.current_editor_session_name,
  mark_session_scope = session_acp.mark_session_scope,
})

local runtime = session_runtime.setup({
  state = state,
  acp_logic = acp_logic,
  agent_logic = agent_logic,
  backend_logic = backend_logic,
  window = window,
  session_view = session_acp.session_view,
  session_agents_for_name = session_acp.session_agents_for_name,
  resolve_saved_snapshot = session_acp.resolve_saved_snapshot,
  current_editor_session_name = session_acp.current_editor_session_name,
  start_interactive_session = function(opts)
    return M.start_interactive_session(opts)
  end,
})

local threads = session_threads.setup({
  state = state,
  acp_logic = acp_logic,
  agent_logic = agent_logic,
  backend_logic = backend_logic,
  start_interactive_session = function(opts)
    return M.start_interactive_session(opts)
  end,
})

local actions = session_actions.setup({
  state = state,
  acp_logic = acp_logic,
  agent_logic = agent_logic,
  backend_logic = backend_logic,
  cache_logic = cache_logic,
  window = window,
  persistence = persistence,
  util = util,
  maybe_kill_pane = session_lifecycle.maybe_kill_pane,
  wait_for_idle_before_close = session_lifecycle.wait_for_idle_before_close,
  maybe_disable_watchers = session_lifecycle.maybe_disable_watchers,
  resolve_acp_target_agent = session_acp.resolve_acp_target_agent,
  current_editor_session_name = session_acp.current_editor_session_name,
  build_resume_prompt = session_conversation.build_resume_prompt,
  select_saved_conversation = session_conversation.select_saved_conversation,
  persist_conversation_capture = session_conversation.persist_conversation_capture,
  backend_supports_persistence = launch.backend_supports_persistence,
  refresh_acp_command_visibility = refresh_acp_command_visibility,
  call_watch = call_watch,
  ensure_session = function(agent_name, agent_cfg, reuse, on_ready)
    return M.ensure_session(agent_name, agent_cfg, reuse, on_ready)
  end,
  start_interactive_session = function(opts)
    return M.start_interactive_session(opts)
  end,
})

local acp_actions = session_acp_actions.setup({
  state = state,
  acp_logic = acp_logic,
  agent_logic = agent_logic,
  backend_logic = backend_logic,
  cache_logic = cache_logic,
  persistence = persistence,
  util = util,
  window = window,
  current_editor_session_name = session_acp.current_editor_session_name,
  current_context_acp_agent = session_acp.current_context_acp_agent,
  active_acp_agents = session_acp.active_acp_agents,
  preferred_session_agent = session_acp.preferred_session_agent,
  resolve_acp_target_agent = session_acp.resolve_acp_target_agent,
  resolve_acp_switch_target_agent = session_acp.resolve_acp_switch_target_agent,
  resolve_active_acp_session = session_acp.resolve_active_acp_session,
  capture_switch_scratch_state = session_acp.capture_switch_scratch_state,
  resolve_switch_anchor = session_acp.resolve_switch_anchor,
  normalize_keep_line_limit = session_conversation.normalize_keep_line_limit,
  split_conversation_checkpoint_lines = session_conversation.split_conversation_checkpoint_lines,
  build_conversation_sidecar = session_conversation.build_conversation_sidecar,
  write_provider_switch_snapshot = session_conversation.write_provider_switch_snapshot,
  read_saved_conversation_lines = session_conversation.read_saved_conversation_lines,
  select_saved_conversation = session_conversation.select_saved_conversation,
  persist_conversation_capture = session_conversation.persist_conversation_capture,
  force_close_session = function(agent_name)
    return actions.force_close_session(agent_name)
  end,
  with_acp_session = function(agent_name, callback)
    return actions.with_acp_session(agent_name, callback)
  end,
  ensure_session = function(agent_name, agent_cfg, reuse, on_ready)
    return M.ensure_session(agent_name, agent_cfg, reuse, on_ready)
  end,
  start_interactive_session = function(opts)
    return M.start_interactive_session(opts)
  end,
  backend_supports_persistence = launch.backend_supports_persistence,
})

M.reopen_acp_window = actions.reopen_acp_window
M.on_session_save_pre = runtime.on_session_save_pre
M.resession_snapshot = runtime.resession_snapshot
M.resession_pre_load = runtime.resession_pre_load
M.resession_post_load = runtime.resession_post_load
M.on_session_load_pre = runtime.on_session_load_pre
M.on_session_load_post = runtime.on_session_load_post
M.ensure_session = launch.ensure_session
M.capture_and_save_session = actions.capture_and_save_session
M.restart_session = actions.restart_session
M.close_session = actions.close_session
M.close_all_sessions = actions.close_all_sessions
M.toggle_session = actions.toggle_session
M.open_instant = actions.open_instant
M.resume_conversation = actions.resume_conversation
M.resume_acp_conversation = acp_actions.resume_acp_conversation
M.restart_acp_session = acp_actions.restart_acp_session
M.restore_acp_restart_state = acp_actions.restore_acp_restart_state
M.pick_acp_sessions = acp_actions.pick_acp_sessions
M.detach_session = acp_actions.detach_session
M.pick_acp_config = acp_actions.pick_acp_config
M.pick_acp_model = acp_actions.pick_acp_model
M.pick_acp_mode = acp_actions.pick_acp_mode
M.switch_acp_provider = acp_actions.switch_acp_provider
M.available_acp_switch_targets = acp_actions.available_acp_switch_targets
M.pick_acp_commands = acp_actions.pick_acp_commands
M.show_acp_tool_timeline = acp_actions.show_acp_tool_timeline
M.pick_acp_resources = acp_actions.pick_acp_resources
M.show_acp_capabilities = acp_actions.show_acp_capabilities
M.show_acp_doctor = acp_actions.show_acp_doctor
M.show_acp_context_budget = acp_actions.show_acp_context_budget
M.show_acp_tool_review = acp_actions.show_acp_tool_review
M.toggle_acp_follow = acp_actions.toggle_acp_follow
M.open_raw_acp_transcript = acp_actions.open_raw_transcript
M.open_full_acp_transcript = acp_actions.open_full_transcript
M.save_conversation_checkpoint = acp_actions.save_conversation_checkpoint
M.start_interactive_session = launch.start_interactive_session
M.attach_session = actions.attach_session
M.pick_acp_threads = threads.pick_threads
M.new_acp_thread = threads.new_thread
M.open_acp_thread = threads.open_thread
M.archive_acp_thread = threads.archive_thread
M.restore_acp_thread = threads.restore_thread
M.rename_acp_thread = threads.rename_thread
M.delete_acp_thread = threads.delete_thread
M.show_acp_thread_changes = threads.show_thread_changes

return M
