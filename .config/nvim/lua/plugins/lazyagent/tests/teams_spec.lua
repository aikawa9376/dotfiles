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
        model = "fast-model",
      },
    },
  }
end

function M.run()
  local config_loader = require("lazyagent.teams.config")
  local runtime = require("lazyagent.teams.runtime")
  local state = require("lazyagent.logic.state")
  local team_commands = require("lazyagent.commands.team")

  local parsed_request, parsed_team = team_commands._parse_args("research investigate parser", {
    "engineering",
    "research",
  })
  assert_equal(parsed_team, "research", "known first argument selects a team")
  assert_equal(parsed_request, "investigate parser", "request follows the selected team")
  local legacy_request, legacy_team = team_commands._parse_args("investigate parser", { "engineering" })
  assert_equal(legacy_team, nil, "ordinary request does not select a team")
  assert_equal(legacy_request, "investigate parser", "ordinary request stays intact")

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

  vim.fn.mkdir(dir .. "/multi/.lazyagent/roles", "p")
  vim.fn.writefile({ "# CTO", "", "Prefer small, reversible decisions." }, dir .. "/multi/.lazyagent/roles/cto.md")
  local multi_path = dir .. "/multi/.lazyagent/teams.json"
  vim.fn.writefile({ vim.json.encode({
    version = 1,
    default_team = "engineering",
    teams = {
      engineering = {
        name = "Engineering",
        lead = "cto",
        worktree = { enabled = true, base = "main" },
        members = {
          cto = {
            agent = "Codex",
            instructions_file = ".lazyagent/roles/cto.md",
            model = "gpt-team-lead",
            reports = {},
          },
        },
      },
      research = {
        name = "Research",
        lead = "analyst",
        members = {
          analyst = { agent = "Gemini", reports = {} },
        },
      },
    },
  }) }, multi_path)
  local catalog, catalog_err = config_loader.load_all(multi_path)
  assert(catalog, catalog_err)
  assert_equal(vim.tbl_count(catalog.teams), 2, "multiple teams share one config")
  local engineering = assert(config_loader.select(catalog))
  assert_equal(engineering.team_id, "engineering", "default team selection")
  assert_equal(engineering.members.cto.model, "gpt-team-lead", "role model is preserved")
  assert(engineering.members.cto.instructions:match("reversible decisions"), "external role Markdown is loaded")
  assert_equal(config_loader.select(catalog, "research").name, "Research", "explicit team selection")

  vim.fn.writefile({ "# outside" }, dir .. "/outside.md")
  local escaped = vim.deepcopy(vim.json.decode(table.concat(vim.fn.readfile(multi_path), "\n")))
  escaped.teams.engineering.members.cto.instructions_file = "../outside.md"
  vim.fn.writefile({ vim.json.encode(escaped) }, multi_path)
  local escaped_catalog, escaped_err = config_loader.load_all(multi_path)
  assert(escaped_catalog == nil and escaped_err:match("must stay inside team root"), "role file cannot escape root")
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

  local previous_opts = state.opts
  local session_logic = require("lazyagent.logic.session")
  local backend_logic = require("lazyagent.logic.backend")
  local Worktree = require("lazyagent.acp.worktree")
  local original_ensure = session_logic.ensure_session
  local original_backend = backend_logic.resolve_backend_for_agent
  local original_create = Worktree.create
  local captured_cfg
  state.opts = vim.tbl_deep_extend("force", vim.deepcopy(previous_opts or {}), {
    interactive_agents = {
      EngineerAgent = {
        acp_cmd = { vim.v.progpath },
        acp = { enabled = true },
      },
    },
  })
  normalized.path = "/repo/.lazyagent/teams.json"
  normalized.root_dir = "/repo"
  normalized.team_id = "engineering"
  normalized.name = "Engineering"
  normalized.members.engineer.agent = "EngineerAgent"
  normalized.members.engineer.worktree = true
  state.team_runtime.config = normalized
  state.team_runtime.members.engineer.thread_id = "123e4567-e89b-42d3-a456-426614174111"
  Worktree.create = function()
    return {
      original_root = "/repo",
      worktree_path = "/tmp/engineer-worktree",
      worktree_branch = "lazyagent/engineering/engineer/test",
      worktree_state = "active",
    }
  end
  session_logic.ensure_session = function(_, cfg, _, callback)
    captured_cfg = cfg
    callback("team-pane", "EngineerAgent::123e4567-e89b-42d3-a456-426614174111")
  end
  backend_logic.resolve_backend_for_agent = function()
    return "buffer_acp", {
      get_runtime_snapshot = function() return { acp_mcp_server_count = 1 } end,
      paste_and_submit = function() return true end,
    }
  end
  local delegated, delegate_err = runtime.delegate({
    team_id = "team-1",
    ["from"] = "cto",
    token = "cto-token",
    to = "engineer",
    assignment = "Implement the scoped change",
  })
  assert(delegated, delegate_err)
  assert_equal(captured_cfg.acp.initial_model, "fast-model", "role model reaches ACP config")
  assert_equal(captured_cfg.root_dir, "/tmp/engineer-worktree", "role session uses managed worktree")
  assert_equal(captured_cfg.stay_hidden, true, "non-lead ACP view stays hidden")
  assert_equal(captured_cfg.acp_thread_metadata.lazyagent_team.role_id, "engineer", "team metadata reaches thread")
  assert_equal(captured_cfg.acp_thread_metadata.worktree_path, "/tmp/engineer-worktree", "worktree metadata reaches thread")
  session_logic.ensure_session = original_ensure
  backend_logic.resolve_backend_for_agent = original_backend
  Worktree.create = original_create
  state.opts = previous_opts
  state.team_runtime = previous

  local tools = require("lazyagent.mcp.tools")
  assert(tools._by_name.team_delegate, "team_delegate MCP tool is registered")
  assert(tools._by_name.team_report, "team_report MCP tool is registered")
  assert(tools._by_name.team_status, "team_status MCP tool is registered")
end

return M
