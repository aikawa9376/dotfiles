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
        effort = "medium",
      },
    },
  }
end

function M.run()
  local config_loader = require("lazyagent.teams.config")
  local runtime = require("lazyagent.teams.runtime")
  local state = require("lazyagent.logic.state")
  local team_commands = require("lazyagent.commands.team")

  assert(runtime._uuid():match("^[0-9a-f]+%-[0-9a-f]+%-4[0-9a-f]+%-8[0-9a-f]+%-[0-9a-f]+$"),
    "team identities use UUID v4 version and variant bits")

  local parsed_request, parsed_team = team_commands._parse_args("research investigate parser", {
    "engineering",
    "research",
  })
  assert_equal(parsed_team, "research", "known first argument selects a team")
  assert_equal(parsed_request, "investigate parser", "request follows the selected team")
  local legacy_request, legacy_team = team_commands._parse_args("investigate parser", { "engineering" })
  assert_equal(legacy_team, nil, "ordinary request does not select a team")
  assert_equal(legacy_request, "investigate parser", "ordinary request stays intact")

  local registered = {}
  team_commands.register(function(name, callback, opts)
    registered[name] = { callback = callback, opts = opts }
  end)
  local original_start = runtime.start
  local original_names = runtime.team_names
  local opened
  runtime.team_names = function() return { "engineering", "research" } end
  runtime.start = function(request, opts)
    opened = { request = request, opts = opts }
    return { config = { name = "Research" } }
  end
  registered.LazyAgentTeam.callback({ args = "research" })
  assert_equal(opened.request, "", "team-only command does not request inline input")
  assert_equal(opened.opts.team, "research", "team-only command keeps selected team")
  assert_equal(opened.opts.open_input, true, "team-only command opens normal scratch input")
  runtime.start = original_start
  runtime.team_names = original_names

  local normalized, err = config_loader.validate(valid_config())
  assert(normalized, err)
  assert_equal(normalized.members.architect.manager, "cto", "manager is derived from reports")
  assert_equal(normalized.members.engineer.manager, "cto", "second manager is derived")
  assert_equal(#normalized.members.engineer.reports, 0, "missing reports defaults to empty")
  assert_equal(normalized.members.engineer.effort, "medium", "reasoning effort is preserved")

  local invalid_effort = valid_config()
  invalid_effort.members.engineer.effort = 42
  local invalid_effort_config, effort_err = config_loader.validate(invalid_effort)
  assert(invalid_effort_config == nil and effort_err:match("effort must be a string"), "invalid effort is rejected")

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
  local original_start_interactive = session_logic.start_interactive_session
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
  normalized.members.cto.agent = "EngineerAgent"
  normalized.members.engineer.agent = "EngineerAgent"
  normalized.members.engineer.worktree = true
  state.team_runtime.config = normalized
  state.team_runtime.members.cto.thread_id = "123e4567-e89b-42d3-a456-426614174110"
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
      get_thread = function() return nil end,
      create_thread = function(attributes) return attributes end,
      get_runtime_snapshot = function() return { acp_mcp_server_count = 1 } end,
      paste_and_submit = function() return true end,
    }
  end
  local opened_cfg
  session_logic.start_interactive_session = function(opts)
    opened_cfg = opts
    opts.on_ready("lead-pane", "EngineerAgent::123e4567-e89b-42d3-a456-426614174110", 1)
  end
  local opened_team, open_err = runtime.start("", { open_input = true })
  assert(opened_team, open_err)
  assert_equal(opened_cfg.open_input, nil, "team uses the standard interactive scratch path")
  assert_equal(opened_cfg.stay_hidden, false, "lead view is visible")
  assert_equal(opened_cfg.initial_input, "", "lead scratch starts empty")
  assert_equal(opened_cfg.acp_thread_id, "123e4567-e89b-42d3-a456-426614174110",
    "lead thread is reserved before the ACP session opens")
  assert(opened_cfg.acp_session_instructions:find("Your role: CTO", 1, true),
    "lead role instructions wait for the first scratch submit")

  local delegated, delegate_err = runtime.delegate({
    team_id = "team-1",
    ["from"] = "cto",
    token = "cto-token",
    to = "engineer",
    assignment = "Implement the scoped change",
  })
  assert(delegated, delegate_err)
  assert_equal(captured_cfg.acp.initial_model, "fast-model", "role model reaches ACP config")
  assert_equal(captured_cfg.acp.initial_effort, "medium", "role reasoning effort reaches ACP config")
  assert(captured_cfg.acp_session_instructions:find("Your role: Engineer", 1, true),
    "role instructions are attached to the ACP session")
  assert_equal(captured_cfg.root_dir, "/tmp/engineer-worktree", "role session uses managed worktree")
  assert_equal(captured_cfg.stay_hidden, true, "non-lead ACP view stays hidden")
  assert_equal(captured_cfg.acp_thread_metadata.lazyagent_team.role_id, "engineer", "team metadata reaches thread")
  assert_equal(captured_cfg.acp_thread_metadata.worktree_path, "/tmp/engineer-worktree", "worktree metadata reaches thread")

  local eager_dir = vim.fn.tempname()
  vim.fn.mkdir(eager_dir .. "/.lazyagent", "p")
  vim.fn.writefile({ vim.json.encode({
    version = 1,
    name = "Eager Team",
    lead = "lead",
    members = {
      lead = { agent = "EngineerAgent", reports = { "implementer", "reviewer" } },
      implementer = { agent = "EngineerAgent", reports = {} },
      reviewer = { agent = "EngineerAgent", reports = {} },
    },
  }) }, eager_dir .. "/.lazyagent/teams.json")
  state.team_runtime = nil
  state.opts.mcp_mode = true
  state.opts._mcp_url = "http://127.0.0.1:12345/mcp"
  state.opts._mcp_type = "http"
  local background_cfgs = {}
  session_logic.ensure_session = function(_, cfg, _, callback)
    background_cfgs[#background_cfgs + 1] = cfg
    callback("background-" .. tostring(#background_cfgs), "background-session-" .. tostring(#background_cfgs))
  end
  session_logic.start_interactive_session = function(opts)
    opened_cfg = opts
    opts.on_ready("lead-pane", "lead-session", 1)
  end
  local eager_result, eager_err = runtime.start("", { open_input = true, start_path = eager_dir })
  assert(eager_result, eager_err)
  assert_equal(#background_cfgs, 2, "all non-lead ACP sessions start with the lead")
  assert_equal(background_cfgs[1].stay_hidden, true, "first background member stays hidden")
  assert_equal(background_cfgs[2].stay_hidden, true, "second background member stays hidden")
  assert_equal(opened_cfg.stay_hidden, false, "eager lead remains visible")
  vim.fn.delete(eager_dir, "rf")

  session_logic.ensure_session = original_ensure
  session_logic.start_interactive_session = original_start_interactive
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
