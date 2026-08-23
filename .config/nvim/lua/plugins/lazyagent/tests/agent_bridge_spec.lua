local M = {}

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run()
  local calls = {}
  local fake_tools = {
    call = function(name, params, context)
      calls[#calls + 1] = { name = name, params = params, context = context }
      if name == "get_agent_status" then
        return { live_agents = { { ref = "agent:target-thread" } } }
      end
      return { success = true, to = params.agent_ref, from = "agent:sender-thread" }
    end,
  }
  local deps = {
    tools = fake_tools,
    state = {
      sessions = {
        ["Codex::sender-thread"] = { thread_id = "sender-thread" },
      },
    },
    identity = {
      thread_id = function(_, session) return session.thread_id end,
    },
  }
  local bridge = require("lazyagent.agent_bridge")

  local listed = bridge.run({ subcommand = "list" }, {}, deps)
  assert_equal(listed.result.live_agents[1].ref, "agent:target-thread", "list result")
  assert_equal(calls[1].name, "get_agent_status", "list MCP tool")

  local sent = bridge.run({
    subcommand = "send",
    agent_ref = "agent:target-thread",
    message = "Commit the render change.",
  }, { sender_session_key = "Codex::sender-thread" }, deps)
  assert_equal(sent.result.to, "agent:target-thread", "send target")
  assert_equal(calls[2].name, "send_to_agent", "send MCP tool")
  assert_equal(calls[2].params.text, "Commit the render change.", "send body")
  assert_equal(calls[2].context.headers["x-lazyagent-thread-id"], "sender-thread", "sender identity")

  local ok, err = pcall(bridge.run, { subcommand = "send", agent_ref = "agent:target-thread" }, {}, deps)
  assert(not ok and tostring(err):find("requires a message", 1, true), "empty messages are rejected")
end

return M
