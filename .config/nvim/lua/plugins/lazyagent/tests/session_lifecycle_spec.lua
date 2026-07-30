local M = {}

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run()
  local lifecycle = require("lazyagent.logic.session.lifecycle")
  local state = require("lazyagent.logic.state")
  local previous_sessions = state.sessions
  local previous_backend = state.backends.buffer_acp
  local previous_opts = state.opts
  local busy = false
  local interrupts = 0
  local kills = 0

  state.opts = {
    interrupt_attempts = 3,
    interrupt_interval_ms = 1,
  }
  state.sessions = {
    Codex = {
      backend = "buffer_acp",
      pane_id = "acp-pane",
    },
  }
  state.backends.buffer_acp = {
    is_busy = function()
      return busy
    end,
    send_keys = function()
      interrupts = interrupts + 1
    end,
    kill_pane_sync = function()
      kills = kills + 1
    end,
  }

  lifecycle.maybe_kill_pane("Codex", "acp-pane", state.backends.buffer_acp, true)
  assert_equal(interrupts, 0, "idle ACP session is not cancelled")
  assert_equal(kills, 1, "idle ACP session is still closed")

  busy = true
  lifecycle.maybe_kill_pane("Codex", "acp-pane", state.backends.buffer_acp, true)
  assert_equal(interrupts, 1, "busy ACP session is cancelled once")
  assert_equal(kills, 2, "busy ACP session is closed after cancellation")

  state.sessions = previous_sessions
  state.backends.buffer_acp = previous_backend
  state.opts = previous_opts
end

return M
