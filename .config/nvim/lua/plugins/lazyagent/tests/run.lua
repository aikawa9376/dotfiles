local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = vim.fs.dirname(vim.fs.dirname(source))

vim.opt.runtimepath:prepend(root)
package.path = table.concat({
  root .. "/?.lua",
  root .. "/?/init.lua",
  package.path,
}, ";")

local suites = {
  "tests.acp.client_contract",
  "tests.acp.cancellation_spec",
  "tests.acp.path_guard_spec",
  "tests.acp.file_writer_spec",
  "tests.acp.terminals_spec",
  "tests.acp.mobile_security_spec",
  "tests.acp.mobile_server_spec",
  "tests.acp.message_stream_spec",
  "tests.acp.content_blocks_spec",
  "tests.acp.view_lifecycle_spec",
  "tests.acp.thread_store_spec",
  "tests.acp.workspace_snapshot_spec",
  "tests.acp.blob_store_spec",
  "tests.acp.change_review_spec",
  "tests.acp.turn_journal_spec",
  "tests.acp.backend_thread_spec",
  "tests.acp.session_identity_spec",
  "tests.acp.session_launch_spec",
  "tests.acp.thread_actions_spec",
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
