local M = {}

local THREAD_A = "123e4567-e89b-42d3-a456-426614174000"
local THREAD_B = "123e4567-e89b-42d3-a456-426614174001"

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run()
  local identity = require("lazyagent.logic.session.identity")
  local legacy = identity.key("Codex", {})
  local first = identity.key("Codex", { acp_thread_id = THREAD_A })
  local second = identity.key("Codex", { acp_thread_id = THREAD_B })

  assert_equal(legacy, "Codex", "legacy agent key")
  assert(first ~= second, "threads for one provider need distinct runtime keys")
  assert_equal(identity.provider_id(first), "Codex", "thread provider identity")
  assert_equal(identity.thread_id(first), THREAD_A, "thread UUID identity")
  assert_equal(identity.is_thread_key(first), true, "thread key detection")
  assert_equal(identity.is_thread_key(legacy), false, "legacy key detection")
  assert_equal(identity.display_name(first), "Codex [123e4567]", "thread display name")
  assert_equal(identity.provider_id("alias", { provider_id = "Copilot" }), "Copilot", "session provider metadata")

  local state = {
    sessions = {
      [first] = { provider_id = "Codex", thread_id = THREAD_A },
      [second] = { provider_id = "Codex", thread_id = THREAD_B },
    },
  }
  identity.activate(state, first, state.sessions[first])
  assert_equal(identity.resolve(state, "Codex"), first, "legacy provider alias")
  identity.activate(state, second, state.sessions[second])
  assert_equal(identity.resolve(state, "Codex"), second, "latest provider alias")
  assert_equal(identity.resolve(state, first), first, "explicit thread key")
end

return M
