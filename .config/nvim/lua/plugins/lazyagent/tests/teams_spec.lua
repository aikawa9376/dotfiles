local M = {}

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

local function valid_config()
  return {
    version = 1,
    name = "Engineering",
    lead = "cto",
    members = {
      cto = {
        agent = "Codex",
        role = "CTO",
        reports = { "architect", "engineer" },
      },
      architect = {
        agent = "Gemini",
        role = "Architect",
        reports = {},
      },
      engineer = {
        agent = "Copilot",
        role = "Engineer",
      },
    },
  }
end

function M.run()
  local config_loader = require("lazyagent.teams.config")
  local runtime = require("lazyagent.teams.runtime")
  local state = require("lazyagent.logic.state")

  local normalized, err = config_loader.validate(valid_config())
  assert(normalized, err)
  assert_equal(normalized.members.architect.manager, "cto", "manager is derived from reports")
  assert_equal(normalized.members.engineer.manager, "cto", "second manager is derived")
  assert_equal(#normalized.members.engineer.reports, 0, "missing reports defaults to empty")

  local duplicate = valid_config()
  duplicate.members.architect.reports = { "engineer" }
  local invalid, duplicate_err = config_loader.validate(duplicate)
  assert(invalid == nil, "duplicate manager must be rejected")
  assert(duplicate_err:match("reports to both"), duplicate_err)

  local unreachable = valid_config()
  unreachable.members.cto.reports = { "architect" }
  local missing, unreachable_err = config_loader.validate(unreachable)
  assert(missing == nil, "unreachable member must be rejected")
  assert(unreachable_err:match("not reachable"), unreachable_err)

  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/project/.lazyagent", "p")
  vim.fn.mkdir(dir .. "/project/src/nested", "p")
  local path = dir .. "/project/.lazyagent/teams.json"
  vim.fn.writefile({ vim.json.encode(valid_config()) }, path)
  assert_equal(
    config_loader.find(dir .. "/project/src/nested", { include_global = false }),
    path,
    "nearest project teams config is discovered"
  )
  local loaded, load_err = config_loader.resolve(dir .. "/project/src/nested", { include_global = false })
  assert(loaded, load_err)
  assert_equal(loaded.root_dir, dir .. "/project", "team root is config directory parent")
  vim.fn.delete(dir, "rf")

  local previous = state.team_runtime
  state.team_runtime = {
    id = "team-1",
    config = normalized,
    members = {
      cto = { token = "cto-token", status = "running" },
      architect = { token = "architect-token", status = "idle" },
      engineer = { token = "engineer-token", status = "idle" },
    },
  }
  local denied, auth_err = runtime.delegate({
    team_id = "team-1",
    ["from"] = "cto",
    token = "wrong",
    to = "engineer",
    assignment = "Implement it",
  })
  assert(denied == nil and auth_err:match("credentials"), "invalid role token must be rejected")

  local no_report, lead_err = runtime.report({
    team_id = "team-1",
    ["from"] = "cto",
    token = "cto-token",
    result = "Done",
  })
  assert(no_report == nil and lead_err:match("human user"), "lead reports only to the user")

  local public_status = runtime.status()
  assert_equal(public_status.active, true, "runtime status is active")
  assert(public_status.members[1].token == nil, "runtime status must not expose credentials")
  state.team_runtime = previous

  local tools = require("lazyagent.mcp.tools")
  assert(tools._by_name.team_delegate, "team_delegate MCP tool is registered")
  assert(tools._by_name.team_report, "team_report MCP tool is registered")
  assert(tools._by_name.team_status, "team_status MCP tool is registered")
end

return M
