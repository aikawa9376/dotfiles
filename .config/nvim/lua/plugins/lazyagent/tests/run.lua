local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = vim.fs.dirname(vim.fs.dirname(source))

vim.opt.runtimepath:prepend(root)
package.path = table.concat({
  root .. "/?.lua",
  root .. "/?/init.lua",
  package.path,
}, ";")

local suites = {
  "tests.util_spec",
  "tests.notes_spec",
  "tests.acp.client_contract",
  "tests.acp.cancellation_spec",
  "tests.acp.path_guard_spec",
  "tests.acp.file_writer_spec",
  "tests.acp.terminals_spec",
  "tests.acp.mobile_security_spec",
  "tests.acp.mobile_server_spec",
  "tests.acp.message_stream_spec",
  "tests.acp.conversation_summary_spec",
  "tests.acp.content_blocks_spec",
  "tests.acp.context_item_spec",
  "tests.acp.prompt_blocks_spec",
  "tests.acp.completion_spec",
  "tests.acp.config_restore_spec",
  "tests.acp.prompt_queue_spec",
  "tests.acp.thread_search_spec",
  "tests.acp.thread_export_spec",
  "tests.acp.notifications_spec",
  "tests.acp.cockpit_spec",
  "tests.acp.editor_registry_spec",
  "tests.acp.agentmux_spec",
  "tests.acp.worktree_spec",
  "tests.acp.worktree_test_spec",
  "tests.acp.registry_spec",
  "tests.acp.mcp_servers_spec",
  "tests.acp.mcp_integration_spec",
  "tests.acp.permission_store_spec",
  "tests.acp.protocol_log_spec",
  "tests.acp.replay_spec",
  "tests.acp.v2_adapter_spec",
  "tests.acp.view_footer_spec",
  "tests.acp.view_follow_spec",
  "tests.acp.view_lifecycle_spec",
  "tests.acp.lifecycle_stress_spec",
  "tests.acp.thread_store_spec",
  "tests.acp.workspace_snapshot_spec",
  "tests.acp.blob_store_spec",
  "tests.acp.blob_gc_spec",
  "tests.acp.change_review_spec",
  "tests.acp.review_feedback_spec",
  "tests.acp.change_apply_spec",
  "tests.acp.follow_spec",
  "tests.acp.turn_journal_spec",
  "tests.acp.backend_thread_spec",
  "tests.acp.session_identity_spec",
  "tests.acp.session_launch_spec",
  "tests.acp.thread_actions_spec",
  "tests.agent_spec",
}

local failures = {}
for _, name in ipairs(suites) do
  local ok, suite_or_error = pcall(require, name)
  if not ok then
    failures[#failures + 1] = name .. ": " .. tostring(suite_or_error)
  else
    local suite_ok, suite_error = xpcall(suite_or_error.run, debug.traceback)
    if not suite_ok then
      failures[#failures + 1] = name .. ":\n" .. tostring(suite_error)
    else
      print("ok - " .. name)
    end
  end
end

if #failures > 0 then
  error(table.concat(failures, "\n\n"), 0)
end

print(string.format("all %d suite(s) passed", #suites))
