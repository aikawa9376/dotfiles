local M = {}

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run()
  local defaults = require("lazyagent.config.defaults").build()
  local agent = require("lazyagent.logic.agent")
  local state = require("lazyagent.logic.state")
  local previous_opts = state.opts

  local antigravity = defaults.interactive_agents.Antigravity
  assert_equal(antigravity.cmd, "agy", "Antigravity CLI command")
  assert_equal(antigravity.acp, false, "Antigravity uses the CLI backend")
  assert_equal(antigravity.yolo_flag, "--dangerously-skip-permissions", "Antigravity yolo flag")

  state.opts = defaults
  antigravity.yolo = true
  assert_equal(agent.use_acp("Antigravity", antigravity), false, "Antigravity does not inherit global ACP")
  assert_equal(
    agent.compute_cli_launch_cmd(antigravity),
    "agy --dangerously-skip-permissions",
    "Antigravity launch command"
  )

  local launch = assert(agent.resolve_launch_spec("Antigravity", antigravity))
  assert_equal(launch.mode, "cli", "Antigravity launch mode")
  assert_equal(launch.command, "agy --dangerously-skip-permissions", "Antigravity launch spec")
  state.opts = previous_opts
end

return M
