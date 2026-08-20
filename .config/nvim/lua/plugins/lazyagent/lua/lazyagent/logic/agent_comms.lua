local M = {}

local identity = require("lazyagent.logic.session.identity")

local function clean_ref(value)
  return vim.trim(tostring(value or "")):gsub("^agent:", "")
end

local function session_thread_id(session_key, session, backend)
  local thread_id = identity.thread_id(session_key, session)
  if thread_id then return thread_id end
  if backend and type(backend.get_runtime_snapshot) == "function" and session and session.pane_id then
    local snapshot = backend.get_runtime_snapshot(session.pane_id)
    return snapshot and snapshot.acp_thread_id or nil
  end
  return nil
end

local function backend_for(session_key, session, deps)
  if deps.backend_for then return deps.backend_for(session_key, session) end
  local runtime_state = deps.state or require("lazyagent.logic.state")
  if session and session.backend and runtime_state.backends and runtime_state.backends[session.backend] then
    return runtime_state.backends[session.backend]
  end
  local provider = identity.provider_id(session_key, session)
  local _, backend = deps.backend_logic.resolve_backend_for_agent(provider, nil)
  return backend
end

function M.list(deps)
  deps = deps or {}
  local runtime_state = deps.state or require("lazyagent.logic.state")
  local agents = {}
  for session_key, session in pairs(runtime_state.sessions or {}) do
    if session and session.pane_id and session.pane_id ~= "" then
      local backend = backend_for(session_key, session, deps)
      local thread_id = session_thread_id(session_key, session, backend)
      local process_id = type(backend and backend.get_pane_pid) == "function"
          and backend.get_pane_pid(session.pane_id)
        or nil
      agents[#agents + 1] = {
        ref = thread_id and ("agent:" .. thread_id) or session_key,
        thread_id = thread_id,
        provider = identity.provider_id(session_key, session),
        title = session.acp_thread_title
          or session.title
          or (session.thread_record and session.thread_record.title),
        status = session.agent_status or "idle",
        process_id = process_id,
        workspace = session.root_dir or session.cwd,
        team = session.lazyagent_team and session.lazyagent_team.role_id or nil,
      }
    end
  end
  table.sort(agents, function(left, right) return left.ref < right.ref end)
  return agents
end

function M.resolve(agent_ref, deps)
  local requested = clean_ref(agent_ref)
  if requested == "" then return nil, "agent_ref must not be empty" end
  local matches = {}
  for _, agent in ipairs(M.list(deps)) do
    local ref = clean_ref(agent.ref)
    if ref == requested
      or agent.thread_id == requested
      or (#requested >= 8 and agent.thread_id and vim.startswith(agent.thread_id, requested))
    then
      matches[#matches + 1] = agent
    end
  end
  if #matches == 0 then return nil, "no live LazyAgent matches '" .. requested .. "'" end
  if #matches > 1 then return nil, "agent_ref is ambiguous: " .. requested end
  return matches[1]
end

local function sender_from_context(context)
  local headers = type(context) == "table" and context.headers or {}
  local thread_id = clean_ref(headers["x-lazyagent-thread-id"])
  return thread_id ~= "" and ("agent:" .. thread_id) or nil
end

function M.send(params, context, deps)
  params = params or {}
  deps = deps or {}
  local text = vim.trim(tostring(params.text or ""))
  if text == "" then return nil, "text must not be empty" end
  local target, resolve_err = M.resolve(params.agent_ref, deps)
  if not target then return nil, resolve_err end

  local runtime_state = deps.state or require("lazyagent.logic.state")
  local target_key, target_session
  for session_key, session in pairs(runtime_state.sessions or {}) do
    local backend = backend_for(session_key, session, deps)
    if session_thread_id(session_key, session, backend) == target.thread_id
      or (not target.thread_id and session_key == target.ref)
    then
      target_key, target_session = session_key, session
      break
    end
  end
  if not target_session then return nil, "target agent is no longer live" end
  local backend = backend_for(target_key, target_session, deps)
  if not backend or type(backend.paste_and_submit) ~= "function" then
    return nil, "target backend cannot accept messages"
  end

  local sender_ref = sender_from_context(context)
  local lines = { "# Message from another LazyAgent agent" }
  if sender_ref then
    lines[1] = "# Message from " .. sender_ref
    lines[#lines + 1] = "Reply with the `send_to_agent` tool using `agent_ref`: `" .. sender_ref .. "`."
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = text
  local accepted = backend.paste_and_submit(target_session.pane_id, table.concat(lines, "\n"), { "C-m" }, {})
  if accepted ~= true and accepted ~= "handled" then return nil, "target rejected the message" end
  return { success = true, accepted = true, to = target.ref, from = sender_ref }
end

return M
