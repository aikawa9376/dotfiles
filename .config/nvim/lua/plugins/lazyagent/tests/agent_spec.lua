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

  local acp = require("lazyagent.logic.acp")
  state.opts = { acp = {} }
  assert_equal(acp.resolve(nil, {}).footer_position, "bottom", "footer defaults to the window bottom")
  assert_equal(acp.resolve(nil, {}).thinking_align, "center", "thinking defaults to horizontal centering")
  state.opts.acp = { footer_position = "inline", thinking_align = "left" }
  assert_equal(acp.resolve(nil, {}).footer_position, "inline", "global legacy footer position")
  assert_equal(acp.resolve(nil, {}).thinking_align, "left", "global thinking alignment")
  local overridden = acp.resolve(nil, { acp = { footer_position = "bottom", thinking_align = "center" } })
  assert_equal(overridden.footer_position, "bottom", "per-agent footer position overrides global")
  assert_equal(overridden.thinking_align, "center", "per-agent thinking alignment overrides global")

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

  local previous_sessions = state.sessions
  local previous_team = state.team_runtime
  state.sessions = {
    ["Codex::lead"] = { pane_id = "lead-pane", provider_id = "Codex" },
    ["Codex::child"] = { pane_id = "child-pane", provider_id = "Codex" },
  }
  state.team_runtime = {
    id = "team-1",
    config = { lead = "lead" },
    members = {
      lead = { session_key = "Codex::lead" },
      child = { session_key = "Codex::child" },
    },
  }
  local selected
  agent.resolve_target_agent(nil, nil, function(choice)
    selected = choice
  end)
  assert_equal(selected, "Codex::lead", "implicit actions target the active team lead")
  state.sessions = previous_sessions
  state.team_runtime = previous_team
  state.opts = previous_opts
end

return M
