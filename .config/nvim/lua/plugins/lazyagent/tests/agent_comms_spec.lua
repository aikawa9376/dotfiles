local M = {}

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run()
  local submitted
  local fake_backend = {
    get_pane_pid = function() return 4242 end,
    paste_and_submit = function(pane_id, text)
      submitted = { pane_id = pane_id, text = text }
      return true
    end,
  }
  local fake_state = {
    sessions = {
      ["Codex::aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"] = {
        pane_id = "acp:target",
        thread_id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
        provider_id = "Codex",
        agent_status = "idle",
      },
    },
  }
  local deps = { state = fake_state, backend_for = function() return fake_backend end }
  local Comms = require("lazyagent.logic.agent_comms")
  local agents = Comms.list(deps)
  assert_equal(agents[1].ref, "agent:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "live agent ref")
  assert_equal(agents[1].process_id, 4242, "live process metadata")

  local result = assert(Comms.send({
    agent_ref = "agent:aaaaaaaa",
    text = "Please review this.",
  }, { headers = { ["x-lazyagent-thread-id"] = "ffffffff-1111-2222-3333-444444444444" } }, deps))
  assert_equal(result.to, agents[1].ref, "message target")
  assert_equal(result.from, "agent:ffffffff-1111-2222-3333-444444444444", "message sender")
  assert_equal(submitted.pane_id, "acp:target", "target pane")
  assert(submitted.text:find("Reply with the `send_to_agent` tool", 1, true), "reply instructions are included")
  assert(submitted.text:find("Please review this.", 1, true), "message body is included")
end

return M
