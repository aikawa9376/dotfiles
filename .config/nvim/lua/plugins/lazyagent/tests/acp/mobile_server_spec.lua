local M = {}

local function assert_truthy(value, label)
  if not value then
    error(label or "expected truthy value", 2)
  end
end

local function http_request(host, port, raw)
  local uv = vim.uv or vim.loop
  local client = uv.new_tcp()
  local chunks = {}
  local done = false
  local request_err
  client:connect(host, port, function(err)
    if err then
      request_err = err
      done = true
      return
    end
    client:write(raw)
    client:read_start(function(read_err, data)
      if read_err then
        request_err = read_err
        done = true
        return
      end
      if data then
        chunks[#chunks + 1] = data
        local response = table.concat(chunks)
        local header_end = response:find("\r\n\r\n", 1, true)
        if header_end then
          local length = tonumber(response:sub(1, header_end):match("[Cc]ontent%-[Ll]ength:%s*(%d+)")) or 0
          if #response >= header_end + 3 + length then
            done = true
            pcall(function() client:read_stop() end)
            pcall(function() client:close() end)
          end
        end
      else
        done = true
      end
    end)
  end)
  if not vim.wait(3000, function() return done end, 10) then
    pcall(function() client:close() end)
    error("timed out waiting for mobile HTTP response", 2)
  end
  assert_truthy(not request_err, "mobile HTTP error: " .. tostring(request_err))
  return table.concat(chunks)
end

local function request(host, port, target, headers, body)
  body = body or ""
  local lines = {
    (body ~= "" and "POST" or "GET") .. " " .. target .. " HTTP/1.1",
    "Host: " .. host .. ":" .. tostring(port),
    "Connection: close",
  }
  for _, header in ipairs(headers or {}) do
    lines[#lines + 1] = header
  end
  lines[#lines + 1] = "Content-Length: " .. tostring(#body)
  lines[#lines + 1] = ""
  lines[#lines + 1] = body
  return http_request(host, port, table.concat(lines, "\r\n"))
end

function M.run()
  local state = require("lazyagent.logic.state")
  local previous_opts = state.opts
  state.opts = vim.tbl_deep_extend("force", {}, state.opts or {}, {
    acp = {
      mobile = {
        host = "127.0.0.1",
        max_body_bytes = 32,
      },
    },
  })

  local mobile = require("lazyagent.acp.mobile")
  local ok, err = xpcall(function()
    assert_truthy(mobile.start(nil, { host = "127.0.0.1", port = 0 }), "start mobile server")
    local host, port, token = mobile.host, mobile.port, mobile.token
    assert_truthy(port and token, "mobile server identity")

    local unauthorized = request(host, port, "/api/status")
    assert_truthy(unauthorized:match("HTTP/1%.1 401 Unauthorized"), "unauthorized request rejected")

    local foreign = request(host, port, "/api/status", {
      "Authorization: Bearer " .. token,
      "Origin: https://evil.example",
    })
    assert_truthy(foreign:match("HTTP/1%.1 403 Forbidden"), "foreign origin rejected")

    local oversized = http_request(host, port, table.concat({
      "POST /api/send HTTP/1.1",
      "Host: " .. host .. ":" .. tostring(port),
      "Authorization: Bearer " .. token,
      "Content-Length: 33",
      "",
      "",
    }, "\r\n"))
    assert_truthy(oversized:match("HTTP/1%.1 413 Payload Too Large"), "oversized request rejected")

    local missing_length = http_request(host, port, table.concat({
      "POST /api/send HTTP/1.1",
      "Host: " .. host .. ":" .. tostring(port),
      "Authorization: Bearer " .. token,
      "",
      "{}",
    }, "\r\n"))
    assert_truthy(missing_length:match("HTTP/1%.1 400 Bad Request"), "missing content length rejected")

    local authorized = request(host, port, "/api/status", {
      "Authorization: Bearer " .. token,
    })
    assert_truthy(authorized:match("HTTP/1%.1 200 OK"), "bearer request accepted")
    assert_truthy(not authorized:match("Access%-Control%-Allow%-Origin:%s*%*"), "CORS wildcard absent")

    local ui = request(host, port, "/?token=" .. token)
    assert_truthy(ui:match("HTTP/1%.1 200 OK"), "token URL accepted")
  end, debug.traceback)

  mobile.stop()
  state.opts = previous_opts
  if not ok then
    error(err, 0)
  end
end

return M
