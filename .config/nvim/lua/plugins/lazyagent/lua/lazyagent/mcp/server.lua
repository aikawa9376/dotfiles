-- lazyagent/mcp/server.lua
-- MCP server: JSON-RPC 2.0 dispatcher over Streamable HTTP transport.
-- Implements the MCP protocol (2025-03-26 spec):
--   initialize / initialized / tools/list / tools/call / ping

local M = {}
local transport = require("lazyagent.mcp.transport")
local tools = require("lazyagent.mcp.tools")

local MCP_VERSION = "2025-03-26"

-- Server info advertised to clients
local SERVER_INFO = {
  name = "lazyagent",
  version = "0.1.0",
}

-- Supported capabilities
local SERVER_CAPABILITIES = {
  tools = { listChanged = false },
}

-- JSON-RPC error codes
local E = {
  PARSE_ERROR      = -32700,
  INVALID_REQUEST  = -32600,
  METHOD_NOT_FOUND = -32601,
  INVALID_PARAMS   = -32602,
  INTERNAL_ERROR   = -32603,
}

local function ok_response(id, result)
  return { jsonrpc = "2.0", id = id, result = result }
end

local function err_response(id, code, message)
  return { jsonrpc = "2.0", id = id, error = { code = code, message = message } }
end

-- Build tools/list result from tools registry
local function tools_list_result()
  local list = {}
  for _, t in ipairs(tools.list) do
    local schema = vim.deepcopy(t.inputSchema)
    -- Ensure properties is a JSON object {} not array [] (Lua empty table encodes as array)
    if type(schema.properties) == "table" and vim.tbl_isempty(schema.properties) then
      schema.properties = vim.empty_dict()
    end
    table.insert(list, {
      name = t.name,
      description = t.description,
      inputSchema = schema,
    })
  end
  return { tools = list }
end

-- Main dispatcher: called by transport for every incoming JSON-RPC object
-- cb(response_or_nil) — nil means notification (no response required)
local function dispatcher(rpc, cb)
  -- Validate JSON-RPC envelope
  if type(rpc) ~= "table" or rpc.jsonrpc ~= "2.0" then
    cb(err_response(vim.NIL, E.INVALID_REQUEST, "Invalid JSON-RPC 2.0 request"))
    return
  end

  local id = rpc.id  -- nil for notifications
  local method = rpc.method
  local params = rpc.params or {}

  -- Notification (no id) — process but don't respond
  if id == nil then
    -- "initialized" notification — no action needed
    cb(nil)
    return
  end

  -- initialize
  if method == "initialize" then
    cb(ok_response(id, {
      protocolVersion = MCP_VERSION,
      capabilities = SERVER_CAPABILITIES,
      serverInfo = SERVER_INFO,
    }))
    return
  end

  -- ping
  if method == "ping" then
    cb(ok_response(id, {}))
    return
  end

  -- tools/list
  if method == "tools/list" then
    cb(ok_response(id, tools_list_result()))
    return
  end

  -- tools/call
  if method == "tools/call" then
    local name = params.name
    local tool_params = params.arguments or {}
    if not name then
      cb(err_response(id, E.INVALID_PARAMS, "tools/call requires 'name'"))
      return
    end
    local result, tool_err = tools.call(name, tool_params)
    if tool_err then
      -- MCP spec: tool errors are returned as content with isError=true
      cb(ok_response(id, {
        content = { { type = "text", text = tool_err.message or "error" } },
        isError = true,
      }))
      return
    end
    cb(ok_response(id, {
      content = { { type = "text", text = vim.fn.json_encode(result) } },
      isError = false,
    }))
    return
  end

  cb(err_response(id, E.METHOD_NOT_FOUND, "Method not found: " .. tostring(method)))
end

-- Start the MCP HTTP server.
-- on_ready(port) is called when the server is listening.
function M.start(on_ready, opts)
  transport.start(dispatcher, on_ready, opts)
end

function M.stop()
  transport.stop()
end

function M.port()
  return transport.port
end

return M
