local M = {}

function M.run()
  local ProtocolLog = require("lazyagent.acp.protocol_log")
  local path = vim.fn.tempname() .. "/protocol.jsonl"
  local log = ProtocolLog.new(path)
  log:record("out", {
    jsonrpc = "2.0", id = 1, method = "session/new",
    params = { cwd = "/repo", mcpServers = { { headers = { Authorization = "Bearer secret" } } } },
  })
  log:record("in", {
    jsonrpc = "2.0", method = "session/update",
    params = { update = { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "hello" } } },
  })
  assert(vim.wait(1000, function() return vim.fn.filereadable(path) == 1 end, 10), "protocol log flush")
  local records = ProtocolLog.read(path)
  assert(#records == 2 and records[1].direction == "out", "protocol records persisted")
  assert(records[1].message.params.mcpServers[1].headers == "<redacted>", "protocol secrets redacted")
  assert(records[2].message.params.update.content.text == "hello", "replay content retained")
  assert(bit.band(vim.uv.fs_stat(path).mode, 511) == 384, "protocol log file mode")
  vim.fn.delete(vim.fs.dirname(path), "rf")
end

return M
