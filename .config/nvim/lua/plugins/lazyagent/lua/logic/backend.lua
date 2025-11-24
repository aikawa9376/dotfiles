-- logic/backend.lua
local M = {}

local state = require("logic.state")
local tmux = require("lazyagent.tmux")
local builtin_backend = require("lazyagent.builtin")

state.backends = { tmux = tmux, builtin = builtin_backend }

--- Resolves the backend module for a given agent.
-- The backend can be specified at multiple levels, with agent-specific
-- configuration taking the highest precedence.
-- @param agent_name (string) The name of the agent.
-- @param agent_cfg (table|nil) The agent's configuration table.
-- @return (string, table) The name and module of the resolved backend.
function M.resolve_backend_for_agent(agent_name, agent_cfg)
  -- Precedence:
  -- 1. explicit agent_cfg.backend (per-agent setting passed to the call / agent config)
  -- 2. existing session backend (for running sessions)
  -- 3. top-level state.opts.backend (global default)
  -- 4. hardcoded fallback "tmux"
  local backend_name = nil
  if agent_cfg and agent_cfg.backend then
    backend_name = agent_cfg.backend
  elseif state.sessions[agent_name] and state.sessions[agent_name].backend then
    backend_name = state.sessions[agent_name].backend
  elseif state.opts and state.opts.backend then
    backend_name = state.opts.backend
  else
    backend_name = "tmux"
  end
  local backend_mod = state.backends[backend_name] or tmux
  return backend_name, backend_mod
end

--- Register a backend module with the internal backend registry.
-- @param name (string) Backend name to register under.
-- @param module (table) Module implementing the backend API (split, paste, send_keys, etc).
-- @return (boolean) True on success, false on invalid arguments.
function M.register_backend(name, module)
  if not name or name == "" or not module then
    return false
  end
  state.backends = state.backends or {}
  state.backends[name] = module
  return true
end

--- Set a global default backend (this updates the runtime opts but doesn't automatically
-- restart or migrate active sessions).
-- @param name (string) The backend name.
-- @return (boolean) True on success.
function M.set_default_backend(name)
  if not name or name == "" then return false end
  state.opts = state.opts or {}
  state.opts.backend = name
  return true
end

--- Set a per-agent backend in the config object (does not affect already-open sessions).
-- @param agent_name (string)
-- @param backend_name (string)
-- @return (boolean) True on success.
function M.set_agent_backend(agent_name, backend_name)
  if not agent_name or agent_name == "" or not backend_name or backend_name == "" then
    return false
  end
  state.opts = state.opts or {}
  state.opts.interactive_agents = state.opts.interactive_agents or {}
  state.opts.interactive_agents[agent_name] = state.opts.interactive_agents[agent_name] or {}
  state.opts.interactive_agents[agent_name].backend = backend_name
  return true
end

--- Return alphabetically sorted list of registered backend names.
-- @return (table) backend name list
function M.available_backends()
  local out = {}
  for k, _ in pairs(state.backends or {}) do table.insert(out, k) end
  table.sort(out)
  return out
end

return M
