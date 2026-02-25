-- lazyagent/mcp/transport.lua
-- Streamable HTTP MCP transport (MCP spec 2025-03-26).
-- Listens on 127.0.0.1:<port> for HTTP POST /mcp requests.
-- Each POST carries a JSON-RPC 2.0 request body.
-- Responses are returned as application/json or text/event-stream
-- (when the client sends Accept: text/event-stream).
--
-- Port is auto-selected and stored in M.port after M.start() is called.

local M = {}

local uv = vim.loop
local state = require("lazyagent.logic.state")

M._server = nil
M.port = nil

-- Find a free TCP port on localhost
local function find_free_port(cb)
  local s = uv.new_tcp()
  s:bind("127.0.0.1", 0)
  local addr = s:getsockname()
  local port = addr and addr.port
  s:close()
  cb(port)
end

-- Parse a raw HTTP request string into { method, path, headers, body }
local function parse_http_request(raw)
  local header_end = raw:find("\r\n\r\n", 1, true)
  if not header_end then return nil end
  local header_part = raw:sub(1, header_end - 1)
  local body = raw:sub(header_end + 4)

  local lines = vim.split(header_part, "\r\n", { plain = true })
  local request_line = lines[1] or ""
  local method, path = request_line:match("^(%u+) (%S+)")
  if not method then return nil end

  local headers = {}
  for i = 2, #lines do
    local k, v = lines[i]:match("^([^:]+):%s*(.+)$")
    if k then headers[k:lower()] = v end
  end

  return { method = method, path = path, headers = headers, body = body }
end

-- Build a minimal HTTP response string
local function http_response(status, content_type, body, extra_headers)
  local lines = {
    "HTTP/1.1 " .. status,
    "Content-Type: " .. content_type,
    "Access-Control-Allow-Origin: *",
    "Access-Control-Allow-Methods: POST, GET, OPTIONS",
    "Access-Control-Allow-Headers: Content-Type, Mcp-Session-Id, Last-Event-Id",
  }
  if extra_headers then
    for _, h in ipairs(extra_headers) do
      table.insert(lines, h)
    end
  end
  if body then
    table.insert(lines, "Content-Length: " .. #body)
    table.insert(lines, "")
    table.insert(lines, body)
  else
    table.insert(lines, "Content-Length: 0")
    table.insert(lines, "")
    table.insert(lines, "")
  end
  return table.concat(lines, "\r\n")
end

-- Format a server-sent event
local function sse_event(data, event_type)
  local out = ""
  if event_type then out = out .. "event: " .. event_type .. "\n" end
  -- data may be multi-line JSON; SSE requires one "data:" per line
  for _, line in ipairs(vim.split(data, "\n", { plain = true })) do
    out = out .. "data: " .. line .. "\n"
  end
  return out .. "\n"
end

-- Handle a single client connection
local function handle_client(client, dispatcher)
  local buf = ""
  client:read_start(function(err, data)
    if err or not data then
      client:close()
      return
    end
    buf = buf .. data

    -- Wait until we have full HTTP headers at minimum
    if not buf:find("\r\n\r\n", 1, true) then return end

    -- read_start runs in a fast event context; move all vim.fn/vim.schedule work out of it
    local raw = buf
    buf = ""
    vim.schedule(function()
      local req = parse_http_request(raw)
      if not req then
        client:write(http_response("400 Bad Request", "text/plain", "Bad Request"))
        client:close()
        return
      end

      -- CORS preflight
      if req.method == "OPTIONS" then
        client:write(http_response("200 OK", "text/plain", "", {
          "Access-Control-Allow-Origin: *",
        }))
        client:shutdown(function() client:close() end)
        return
      end

      if req.path ~= "/mcp" then
        client:write(http_response("404 Not Found", "text/plain", "Not Found"))
        client:shutdown(function() client:close() end)
        return
      end

      -- GET /mcp — Gemini CLI tries this after notifications/initialized.
      -- Return 405 to signal "SSE not supported"; client falls back to POST-only mode.
      if req.method == "GET" then
        client:write(http_response("405 Method Not Allowed", "text/plain", "SSE not supported"))
        client:shutdown(function() client:close() end)
        return
      end

      -- POST /mcp — JSON-RPC request
      if req.method == "POST" then
        local ok, rpc = pcall(vim.fn.json_decode, req.body)
        if not ok or type(rpc) ~= "table" then
          client:write(http_response("400 Bad Request", "application/json",
            vim.fn.json_encode({ jsonrpc = "2.0", error = { code = -32700, message = "Parse error" }, id = vim.NIL })))
          client:shutdown(function() client:close() end)
          return
        end

        local accept = req.headers["accept"] or ""
        local want_sse = accept:find("text/event%-stream") ~= nil

        dispatcher(rpc, function(response)
          if not response then
            -- Notification (no id): return 202 Accepted with empty body
            client:write(http_response("202 Accepted", "application/json", ""))
            client:shutdown(function() client:close() end)
            return
          end
          local json = vim.fn.json_encode(response)
          if want_sse then
            local header = table.concat({
              "HTTP/1.1 200 OK",
              "Content-Type: text/event-stream",
              "Cache-Control: no-cache",
              "Access-Control-Allow-Origin: *",
              "",
              "",
            }, "\r\n")
            client:write(header)
            client:write(sse_event(json, "message"))
            client:shutdown(function() client:close() end)
          else
            client:write(http_response("200 OK", "application/json", json))
            client:shutdown(function() client:close() end)
          end
        end)
        return
      end

      client:write(http_response("405 Method Not Allowed", "text/plain", "Method Not Allowed"))
      client:shutdown(function() client:close() end)
    end)
  end)
end

-- Start the MCP server (TCP or Unix domain socket).
-- opts.port (number|nil): fixed port to listen on; 0 or nil = auto-select
-- opts.sock_path (string|nil): listen on unix domain socket at this path
function M.start(dispatcher, on_ready, opts)
  if M._server then
    if on_ready then on_ready(M.port or M.sock_path) end
    return
  end

  opts = opts or {}
  local fixed_port = opts.port and opts.port ~= 0 and opts.port or nil
  local sock_path = opts.sock_path

  local function do_listen_tcp(port)
    M.port = port
    M.sock_path = nil

    local server = uv.new_tcp()
    local ok, err = pcall(function() server:bind("127.0.0.1", port) end)
    if not ok then
      vim.notify("[lazyagent MCP] bind error on port " .. port .. ": " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    server:listen(128, function(lerr)
      if lerr then
        vim.notify("[lazyagent MCP] listen error: " .. tostring(lerr), vim.log.levels.ERROR)
        return
      end
      local client = uv.new_tcp()
      server:accept(client)
      handle_client(client, dispatcher)
    end)
    M._server = server

    if state.opts and state.opts.debug then
      vim.notify("[lazyagent MCP] Listening on http://127.0.0.1:" .. port .. "/mcp", vim.log.levels.INFO)
    end

    if on_ready then on_ready(port) end
  end

  local function do_listen_sock(path)
    M.port = nil
    M.sock_path = path

    -- remove stale socket file if present
    pcall(function() vim.loop.fs_unlink(path) end)

    local server = uv.new_pipe(false)
    local ok, err = pcall(function() server:bind(path) end)
    if not ok then
      vim.notify("[lazyagent MCP] bind error on socket " .. path .. ": " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    server:listen(128, function(lerr)
      if lerr then
        vim.notify("[lazyagent MCP] listen error: " .. tostring(lerr), vim.log.levels.ERROR)
        return
      end
      local client = uv.new_pipe(false)
      server:accept(client)
      handle_client(client, dispatcher)
    end)
    M._server = server

    if state.opts and state.opts.debug then
      vim.notify("[lazyagent MCP] Listening on unix socket " .. path, vim.log.levels.INFO)
    end

    if on_ready then on_ready(path) end
  end

  if sock_path then
    do_listen_sock(sock_path)
  elseif fixed_port then
    do_listen_tcp(fixed_port)
  else
    find_free_port(function(port)
      if not port then
        vim.notify("[lazyagent MCP] Failed to find free port", vim.log.levels.ERROR)
        return
      end
      do_listen_tcp(port)
    end)
  end
end

function M.stop()
  if M._server then
    pcall(function() M._server:close() end)
    M._server = nil
    M.port = nil
  end
  if M.sock_path then
    pcall(function() vim.loop.fs_unlink(M.sock_path) end)
    M.sock_path = nil
  end
end

return M
