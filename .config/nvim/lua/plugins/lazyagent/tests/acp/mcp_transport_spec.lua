local M = {}

function M.run()
  local uv = vim.uv
  local transport = require('lazyagent.mcp.transport')
  transport.stop()
  transport.start(function(_, done) done(nil) end)
  local port = assert(transport.port)
  for _ = 1, 10 do
    local peer = uv.new_tcp()
    local connected, reply
    peer:connect('127.0.0.1', port, function(err)
      assert(not err, err)
      connected = true
      peer:read_start(function(_, data) if data then reply = data end end)
      peer:write('GET /events HTTP/1.1\r\nHost: localhost\r\n\r\n')
    end)
    assert(vim.wait(500, function() return connected and reply ~= nil end, 5))
    assert(#transport._sse_clients == 1, 'SSE connection registered')
    peer:close()
    assert(vim.wait(500, function() return #transport._sse_clients == 0 end, 5),
      'disconnected SSE peer retained its handle')
  end

  -- Stop must also release peers that have not finished sending HTTP headers.
  local peer = uv.new_tcp()
  local connected, eof
  peer:connect('127.0.0.1', port, function(err)
    assert(not err, err)
    connected = true
    peer:read_start(function(_, data) if data == nil then eof = true end end)
    peer:write('POST /mcp HTTP/1.1\r\nHost: localhost\r\n')
  end)
  assert(vim.wait(500, function() return connected end, 5))
  vim.wait(20, function() return false end, 5)
  transport.stop()
  assert(vim.wait(500, function() return eof end, 5), 'stop retained an incomplete HTTP connection')
  peer:close()
  assert(transport.port == nil and transport._server == nil and #transport._sse_clients == 0)

  local blocker = uv.new_tcp()
  assert(blocker:bind('127.0.0.1', 0))
  assert(blocker:listen(1, function() end))
  local notify = vim.notify
  vim.notify = function() end
  for _ = 1, 10 do
    transport.start(function() end, nil, { port = blocker:getsockname().port })
    assert(transport._server == nil and transport.port == nil, 'failed listener published a server handle')
  end
  vim.notify = notify
  blocker:close()
  vim.wait(20, function() return false end, 5)
  local tcp = 0
  uv.walk(function(handle) if handle:get_type() == 'tcp' and not handle:is_closing() then tcp = tcp + 1 end end)
  assert(tcp == 0, 'connection/listen failures leaked TCP handles')
end

return M
