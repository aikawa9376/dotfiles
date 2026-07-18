-- logic/state.lua
-- This module holds the shared state for the lazyagent plugin,
-- such as configuration, active sessions, and other runtime properties.

local M = {
  -- Plugin options, initialized by setup()
  opts = {},

  -- Table to track active agent sessions.
  -- The key is the agent name, and value contains session info like pane_id.
  sessions = {},

  -- The name of the currently active/focused agent in the scratch buffer.
  open_agent = nil,

  -- Session-switch runtime state keyed by editor session identity.
  session_views = {},

  -- Name of the currently loaded editor session when managed via resession hooks.
  current_session_name = nil,

  -- Unique for this Neovim process lifetime; persisted on ACP threads for ownership checks.
  editor_instance_id = table.concat({ tostring(vim.fn.getpid()), tostring((vim.uv or vim.loop).hrtime()) }, ":"),

  -- Flag to ensure setup is only run once.
  _configured = false,

  -- A table to hold backend modules
  backends = {},
}

return M
