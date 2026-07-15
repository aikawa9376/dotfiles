local M = {}

function M.run()
  local Export = require("lazyagent.acp.thread_export")
  local refs = { message = "restored assistant body", raw = "full raw tool output" }
  local markdown = Export.render({
    title = "Fixture thread",
    provider_id = "fixture",
    cwd = "/tmp/project",
    thread_id = "thread-1",
    conversation = {
      { id = "1", heading = "User", body = "hello" },
      { id = "2", heading = "Assistant", body_ref = { path = "message" } },
      { id = "3", heading = "Tool search", body = "summary", toolCallId = "tool-1" },
    },
    tools = {
      { toolCallId = "tool-1", rendered_raw_output_ref = { path = "raw" } },
    },
    read_ref = function(ref) return refs[ref and ref.path] or "" end,
  })
  assert(markdown:match("# Fixture thread"), "export title")
  assert(markdown:match("## User\n\nhello"), "export user message")
  assert(markdown:match("## Assistant\n\nrestored assistant body"), "export body ref")
  assert(markdown:match("### Raw tool output\n\n    full raw tool output"), "export raw tool ref")
  assert(markdown:match("Thread: `thread%-1`"), "export metadata")
end

return M
