local M = {}

local function clean(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

function M.key(provider_id, agent_cfg)
  provider_id = clean(provider_id)
  local thread_id = clean(agent_cfg and (agent_cfg.acp_thread_id or agent_cfg.thread_id) or "")
  if provider_id == "" or thread_id == "" then
    return provider_id
  end
  return provider_id .. "::" .. thread_id:lower()
end

function M.provider_id(session_key, session)
  if type(session) == "table" and session.provider_id and session.provider_id ~= "" then
    return session.provider_id
  end
  return clean(session_key):match("^(.-)::[0-9a-fA-F%-]+$") or clean(session_key)
end

function M.thread_id(session_key, session)
  if type(session) == "table" and session.thread_id and session.thread_id ~= "" then
    return session.thread_id
  end
  return clean(session_key):match("::([0-9a-fA-F%-]+)$")
end

function M.is_thread_key(session_key)
  return M.thread_id(session_key) ~= nil
end

function M.display_name(session_key, session)
  local provider_id = M.provider_id(session_key, session)
  local thread_id = M.thread_id(session_key, session)
  if not thread_id then
    return provider_id
  end
  return string.format("%s [%s]", provider_id, thread_id:sub(1, 8))
end

function M.activate(state, session_key, session)
  if type(state) ~= "table" or not session_key or session_key == "" then
    return session_key
  end
  session = session or (state.sessions and state.sessions[session_key]) or nil
  local provider_id = M.provider_id(session_key, session)
  state.session_aliases = state.session_aliases or {}
  if provider_id ~= "" then
    state.session_aliases[provider_id] = session_key
  end
  return session_key
end

function M.resolve(state, requested)
  requested = clean(requested)
  local sessions = type(state) == "table" and state.sessions or nil
  if requested == "" or type(sessions) ~= "table" then
    return requested, nil
  end
  if sessions[requested] then
    return requested, sessions[requested]
  end
  local alias = state.session_aliases and state.session_aliases[requested] or nil
  if alias and sessions[alias] then
    return alias, sessions[alias]
  end
  if state.open_agent and sessions[state.open_agent]
    and M.provider_id(state.open_agent, sessions[state.open_agent]) == requested
  then
    return state.open_agent, sessions[state.open_agent]
  end
  local match_key = nil
  local match = nil
  for session_key, session in pairs(sessions) do
    if M.provider_id(session_key, session) == requested then
      if match then
        return requested, nil
      end
      match_key = session_key
      match = session
    end
  end
  return match_key or requested, match
end

return M
