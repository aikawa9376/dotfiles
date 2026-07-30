local M = {}

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run()
  local state = require("lazyagent.logic.state")
  local status = require("lazyagent.logic.status")
  local previous_sessions = state.sessions

  state.sessions = {
    ["Codex::11111111-1111-1111-1111-111111111111"] = {
      pane_id = "pane-1",
      provider_id = "Codex",
    },
    ["Codex::22222222-2222-2222-2222-222222222222"] = {
      pane_id = "pane-2",
      provider_id = "Codex",
    },
  }
  assert_equal(status.get_status(), "2", "same-provider sessions use a count")

  state.sessions = {
    ["Codex::33333333-3333-3333-3333-333333333333"] = {
      pane_id = "pane-3",
      provider_id = "Codex",
      lazyagent_team = { id = "team-1", role_id = "lead", lead = true },
    },
    ["Copilot::44444444-4444-4444-4444-444444444444"] = {
      pane_id = "pane-4",
      provider_id = "Copilot",
      lazyagent_team = { id = "team-1", role_id = "engineer", lead = false },
    },
    ["Gemini::55555555-5555-5555-5555-555555555555"] = {
      pane_id = "pane-5",
      provider_id = "Gemini",
      lazyagent_team = { id = "team-1", role_id = "reviewer", lead = false },
    },
  }
  assert_equal(status.get_status(), "", "team members use one team icon")

  state.sessions["Copilot::44444444-4444-4444-4444-444444444444"].agent_status = "waiting"
  assert_equal(status.get_status(), " ?", "team waiting state is aggregated")

  state.sessions.Cursor = { pane_id = "pane-6", provider_id = "Cursor" }
  assert_equal(status.get_status(), " ? ", "team and standalone provider groups coexist")

  state.sessions = previous_sessions
end

return M
