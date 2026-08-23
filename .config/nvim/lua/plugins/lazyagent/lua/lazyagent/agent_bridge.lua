local M = {}

local function tool_error(err)
  if type(err) == "table" and err.message then
    return tostring(err.message)
  end
  return tostring(err or "LazyAgent agent communication failed")
end

local function sender_context(request, state, identity)
  local session_key = tostring(request.sender_session_key or "")
  if session_key == "" then return {} end
  local session = state.sessions and state.sessions[session_key] or nil
  if not session then return {} end
  local thread_id = identity.thread_id(session_key, session)
  if not thread_id then return {} end
  return { headers = { ["x-lazyagent-thread-id"] = thread_id } }
end

function M.run(args, request, deps)
  args = args or {}
  request = request or {}
  deps = deps or {}
  local tools = deps.tools or require("lazyagent.mcp.tools")
  local state = deps.state or require("lazyagent.logic.state")
  local identity = deps.identity or require("lazyagent.logic.session.identity")
  local subcommand = args.subcommand or "list"

  if subcommand == "list" or subcommand == "status" then
    local result, err = tools.call("get_agent_status", {}, {})
    if not result then error(tool_error(err)) end
    return { result = result }
  end

  if subcommand == "send" then
    local agent_ref = vim.trim(tostring(args.agent_ref or ""))
    local message = tostring(args.message or "")
    if agent_ref == "" then error("lazyagent-agent send requires an agent ref") end
    if vim.trim(message) == "" then error("lazyagent-agent send requires a message") end
    local result, err = tools.call("send_to_agent", {
      agent_ref = agent_ref,
      text = message,
    }, sender_context(request, state, identity))
    if not result then error(tool_error(err)) end
    return { result = result }
  end

  error("unsupported lazyagent-agent subcommand: " .. tostring(subcommand))
end

return M
