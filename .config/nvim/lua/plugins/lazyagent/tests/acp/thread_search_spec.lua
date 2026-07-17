local M = {}

local function assert_equal(expected, actual, label)
  if not vim.deep_equal(expected, actual) then
    error(string.format("%s: expected %s, got %s", label, vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

function M.run()
  local Search = require("lazyagent.acp.thread_search")
  local refs = {
    ["message"] = "compacted assistant answer with NeedleMessage",
    ["raw"] = "expanded raw output contains NeedleTool",
  }
  local conversation = {
    { id = "1", kind = "user", title = "User", body = "ordinary prompt" },
    { id = "2", kind = "thinking", title = "Thinking", body_chunks = { "consider NeedleThought carefully" } },
    { id = "3", kind = "assistant", title = "Assistant", body_ref = { path = "message" } },
  }
  local tools = {
    { toolCallId = "tool-1", title = "Search", rendered_raw_output_ref = { path = "raw" } },
  }
  local opts = { read_ref = function(ref) return refs[ref and ref.path] or "" end }

  local thought = Search.search(conversation, tools, "needlethought", opts)
  assert_equal(1, #thought, "thought search result count")
  assert_equal("thinking", thought[1].kind, "thought search kind")
  assert_equal("2", thought[1].id, "thought search identity")

  local message = Search.search(conversation, tools, "needLEmessage", opts)
  assert_equal("conversation", message[1].target, "compacted message search target")
  assert_equal("3", message[1].id, "compacted message identity")

  local tool = Search.search(conversation, tools, "needletool", opts)
  assert_equal(1, #tool, "tool search result count")
  assert_equal("tool", tool[1].target, "expanded tool search target")
  assert_equal("tool-1", tool[1].tool_call_id, "expanded tool search identity")
  assert_equal({}, Search.search(conversation, tools, "", opts), "empty query results")

  local path = vim.fn.tempname() .. "-thread-search.log"
  local prefix = string.rep("x", 65530)
  vim.fn.writefile({ prefix .. "CrossChunkNeedle" .. string.rep("y", 65536) }, path, "b")
  local streamed = Search.search({
    { id = "streamed", kind = "assistant", title = "Assistant", body_ref = { path = path } },
  }, {}, "crosschunkneedle")
  assert_equal(1, #streamed, "streamed large ref result count")
  assert_equal("streamed", streamed[1].id, "streamed large ref identity")
  vim.fn.delete(path)
end

return M
