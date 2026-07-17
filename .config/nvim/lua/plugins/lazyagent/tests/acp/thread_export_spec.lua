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

  local ref_path = vim.fn.tempname() .. "-thread-export-ref.log"
  local range_path = vim.fn.tempname() .. "-thread-export-range.log"
  local export_path = vim.fn.tempname() .. "-thread-export.md"
  local large = string.rep("streamed output ", 10000)
  vim.fn.writefile({ large }, ref_path, "b")
  vim.fn.writefile({ "skip header", "wanted one", "wanted two", "skip trailer" }, range_path, "b")
  assert(Export.write({
    title = "Streamed thread",
    conversation = {
      { heading = "Assistant", body_ref = { path = range_path, start_line = 2, end_line = 3 } },
      { heading = "Tool", body = "summary", toolCallId = "tool-stream" },
    },
    tools = {
      { toolCallId = "tool-stream", rendered_raw_output_ref = { path = ref_path } },
    },
  }, export_path))
  local exported = table.concat(vim.fn.readfile(export_path), "\n")
  assert(exported:match("# Streamed thread"), "streaming export title")
  assert(exported:match("### Raw tool output"), "streaming export section")
  assert(exported:find("wanted one\nwanted two", 1, true), "streaming export line range")
  assert(not exported:find("skip header", 1, true), "streaming export excludes lines before range")
  assert(exported:find("    streamed output", 1, true), "streaming export indentation")
  assert(exported:find(large:sub(-1000), 1, true), "streaming export retains complete ref")
  vim.fn.delete(ref_path)
  vim.fn.delete(range_path)
  vim.fn.delete(export_path)
end

return M
