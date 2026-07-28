local M = {}

local state = require("lazyagent.logic.state")
local config_loader = require("lazyagent.teams.config")
local agent_logic = require("lazyagent.logic.agent")
local backend_logic = require("lazyagent.logic.backend")
local mcp_integration = require("lazyagent.integrations.mcp")

local function uuid()
  local seed = table.concat({
    tostring(vim.fn.getpid()),
    tostring((vim.uv or vim.loop).hrtime()),
    tostring(math.random()),
  }, ":")
  local hash = vim.fn.sha256(seed)
  return table.concat({
    hash:sub(1, 8),
    hash:sub(9, 12),
    hash:sub(13, 16),
    hash:sub(17, 20),
    hash:sub(21, 32),
  }, "-")
end

local function active()
  return state.team_runtime
end

local function member_summary(team, role_id)
  local member = team.config.members[role_id]
  local reports = {}
  for _, child_id in ipairs(member.reports or {}) do
    local child = team.config.members[child_id]
    reports[#reports + 1] = string.format("%s (%s, agent=%s)", child_id, child.role, child.agent)
  end
  return #reports > 0 and table.concat(reports, ", ") or "none"
end

local function role_prompt(team, role_id)
  local member = team.config.members[role_id]
  local lines = {
    "# LazyAgent Teams role",
    "",
    "The human user is the ultimate authority. You are one member of an AI organization and must stay within this role.",
    string.format("Team: %s", team.config.name),
    string.format("Your member id: %s", role_id),
    string.format("Your role: %s", member.role),
    string.format("Your manager: %s", member.manager or "human user"),
    string.format("Your direct reports: %s", member_summary(team, role_id)),
    "",
  }
  if member.instructions ~= "" then
    lines[#lines + 1] = "Role-specific instructions:"
    lines[#lines + 1] = member.instructions
    lines[#lines + 1] = ""
  end
  if #member.reports > 0 then
    lines[#lines + 1] = "You may delegate only to your direct reports with the `team_delegate` MCP tool."
    lines[#lines + 1] = "Plan work, give each report a bounded assignment, and integrate their reports before presenting a conclusion."
  else
    lines[#lines + 1] = "You have no direct reports; do not attempt further delegation."
  end
  if member.manager then
    lines[#lines + 1] = "When your assignment is complete, call `team_report` exactly once with a concise result for your manager."
  else
    lines[#lines + 1] = "You are the lead. Return the final integrated decision to the human user."
  end
  lines[#lines + 1] = "For team tools, always pass these exact credentials:"
  lines[#lines + 1] = string.format("- team_id: %s", team.id)
  lines[#lines + 1] = string.format("- from: %s", role_id)
  lines[#lines + 1] = string.format("- token: %s", team.members[role_id].token)
  return table.concat(lines, "\n")
end

local function build_member_config(team, role_id)
  local member = team.config.members[role_id]
  local base = agent_logic.get_interactive_agent(member.agent)
  if not base then
    return nil, "agent '" .. member.agent .. "' is not configured"
  end
  local acp = type(base.acp) == "table" and vim.deepcopy(base.acp) or {}
  acp.enabled = true
  local cfg = vim.tbl_deep_extend("force", vim.deepcopy(base), {
    acp = acp,
    acp_thread_id = team.members[role_id].thread_id,
    root_dir = team.config.root_dir,
    cwd = team.config.root_dir,
    stay_hidden = role_id ~= team.config.lead,
    lazyagent_team = {
      id = team.id,
      role_id = role_id,
    },
  })
  local command, command_err = agent_logic.resolve_acp_command(member.agent, cfg)
  if not command then
    return nil, command_err or ("agent '" .. member.agent .. "' does not support ACP")
  end
  return cfg
end

local function send_to_member(team, role_id, text, callback)
  local runtime_member = team.members[role_id]
  runtime_member.status = "starting"
  runtime_member.error = nil
  local function fail(message)
    runtime_member.status = "failed"
    runtime_member.error = message
    vim.schedule(function()
      vim.notify(
        string.format("LazyAgentTeam: %s failed: %s", role_id, message),
        vim.log.levels.ERROR
      )
    end)
    if callback then callback(nil, message) end
  end
  local cfg, cfg_err = build_member_config(team, role_id)
  if not cfg then
    fail(cfg_err)
    return nil, cfg_err
  end
  local session_logic = require("lazyagent.logic.session")
  session_logic.ensure_session(team.config.members[role_id].agent, cfg, true, function(pane_id, session_key)
    runtime_member.session_key = session_key
    runtime_member.pane_id = pane_id
    if active() ~= team then
      pcall(session_logic.close_session, session_key)
      return
    end
    runtime_member.status = "running"
    local _, backend = backend_logic.resolve_backend_for_agent(session_key, cfg)
    if not backend or type(backend.paste_and_submit) ~= "function" then
      fail("ACP backend cannot submit prompts")
      return
    end
    local snapshot = type(backend.get_runtime_snapshot) == "function" and backend.get_runtime_snapshot(pane_id) or nil
    if snapshot and snapshot.acp_mcp_server_count == 0 then
      fail("agent ACP capabilities do not accept the Teams HTTP MCP control server")
      return
    end
    local result = backend.paste_and_submit(pane_id, text, cfg.submit_keys, {})
    if result == false then
      fail("failed to submit prompt")
      return
    end
    if callback then callback(true) end
  end)
  return true
end

local function credentials(params)
  local team = active()
  if not team then
    return nil, nil, "no active LazyAgent team"
  end
  if params.team_id ~= team.id then
    return nil, nil, "team_id does not match the active team"
  end
  local role_id = tostring(params.from or "")
  local member = team.members[role_id]
  if not member or member.token ~= params.token then
    return nil, nil, "invalid team member credentials"
  end
  return team, role_id
end

function M.delegate(params)
  params = params or {}
  local team, from, auth_err = credentials(params)
  if not team then return nil, auth_err end
  local target = tostring(params.to or "")
  local assignment = vim.trim(tostring(params.assignment or ""))
  if assignment == "" then
    return nil, "assignment must not be empty"
  end
  local allowed = false
  for _, child in ipairs(team.config.members[from].reports or {}) do
    if child == target then allowed = true break end
  end
  if not allowed then
    return nil, string.format("'%s' may delegate only to direct reports: %s", from, member_summary(team, from))
  end

  local prompt = table.concat({
    role_prompt(team, target),
    "",
    "# Assignment from " .. from,
    assignment,
  }, "\n")
  local ok, launch_err = send_to_member(team, target, prompt)
  if not ok then return nil, launch_err end
  team.members[target].assigned_by = from
  team.members[target].assignment = assignment
  return {
    accepted = true,
    team = team.config.name,
    from = from,
    to = target,
    status = team.members[target].status,
  }
end

function M.report(params)
  params = params or {}
  local team, from, auth_err = credentials(params)
  if not team then return nil, auth_err end
  local member = team.config.members[from]
  if not member.manager then
    return nil, "the lead reports directly to the human user"
  end
  if team.members[from].status == "reported" then
    return nil, "this assignment was already reported"
  end
  local result = vim.trim(tostring(params.result or ""))
  if result == "" then
    return nil, "result must not be empty"
  end
  team.members[from].status = "reported"
  team.members[from].result = result

  local manager = member.manager
  local message = table.concat({
    string.format("# Team report from %s (%s)", from, member.role),
    result,
    "",
    "Integrate this report with the other work. Delegate follow-up only if needed.",
  }, "\n")
  local ok, send_err = send_to_member(team, manager, message)
  if not ok then return nil, send_err end
  return { accepted = true, from = from, to = manager }
end

function M.status()
  local team = active()
  if not team then
    local pending = state.team_start_pending
    return {
      active = false,
      pending = pending ~= nil,
      name = pending and pending.config and pending.config.name or nil,
      config_path = pending and pending.config and pending.config.path or nil,
    }
  end
  local members = {}
  for id, runtime_member in pairs(team.members) do
    local config_member = team.config.members[id]
    members[#members + 1] = {
      id = id,
      role = config_member.role,
      agent = config_member.agent,
      manager = config_member.manager,
      status = runtime_member.status,
      session_key = runtime_member.session_key,
      has_result = runtime_member.result ~= nil,
    }
  end
  table.sort(members, function(a, b) return a.id < b.id end)
  return {
    active = true,
    id = team.id,
    name = team.config.name,
    lead = team.config.lead,
    config_path = team.config.path,
    members = members,
  }
end

local function begin(config, request)
  local team = {
    id = uuid(),
    config = config,
    members = {},
    started_at = os.time(),
  }
  for id in pairs(config.members) do
    team.members[id] = {
      token = uuid(),
      thread_id = uuid(),
      status = "idle",
    }
  end
  state.team_runtime = team

  local lead_prompt = table.concat({
    role_prompt(team, config.lead),
    "",
    "# Request from the human user",
    request,
  }, "\n")
  local ok, err = send_to_member(team, config.lead, lead_prompt)
  if not ok then
    state.team_runtime = nil
    return nil, err
  end
  return team
end

local function preflight(config)
  for id, member in pairs(config.members) do
    local base = agent_logic.get_interactive_agent(member.agent)
    if not base then
      return nil, string.format("member '%s' references unconfigured agent '%s'", id, member.agent)
    end
    local _, command_err = agent_logic.resolve_acp_command(member.agent, base)
    if command_err then
      return nil, string.format("member '%s': %s", id, command_err)
    end
  end
  return true
end

function M.start(request, opts)
  opts = opts or {}
  request = vim.trim(tostring(request or ""))
  if request == "" then
    return nil, "request must not be empty"
  end
  local source = opts.start_path
  if not source or source == "" then
    local current = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
    source = current ~= "" and current or vim.fn.getcwd()
  end
  local teams_opts = (state.opts and state.opts.teams) or {}
  if teams_opts.enabled == false then
    return nil, "Teams is disabled by teams.enabled = false"
  end
  local config, config_err = config_loader.resolve(source, { path = opts.path or teams_opts.path })
  if not config then return nil, config_err end
  local ready, preflight_err = preflight(config)
  if not ready then return nil, preflight_err end

  if active() then
    if active().config.path ~= config.path then
      return nil, "another LazyAgent team is already active; stop it before switching configs"
    end
    local lead = active().config.lead
    local prompt = "# Follow-up request from the human user\n" .. request
    local ok, send_err = send_to_member(active(), lead, prompt)
    return ok and active() or nil, send_err
  end
  if state.team_start_pending then
    return nil, "a LazyAgent team is already starting"
  end

  if not state.opts.mcp_mode then
    return nil, "LazyAgent Teams requires mcp_mode = true"
  end
  mcp_integration.ensure_started(state.opts)
  local pending = { config = config }
  state.team_start_pending = pending
  local attempts = 0
  local function wait_for_mcp()
    if state.team_start_pending ~= pending then
      return
    end
    attempts = attempts + 1
    if state.opts._mcp_url then
      state.team_start_pending = nil
      local team, start_err = begin(config, request)
      if not team then
        vim.notify("LazyAgentTeam: " .. tostring(start_err), vim.log.levels.ERROR)
      end
      return
    end
    if attempts >= 50 then
      state.team_start_pending = nil
      vim.notify("LazyAgentTeam: MCP server did not become ready", vim.log.levels.ERROR)
      return
    end
    vim.defer_fn(wait_for_mcp, 100)
  end
  wait_for_mcp()
  return { pending = true, config = config }
end

function M.stop()
  local team = active()
  local stopped_pending = state.team_start_pending ~= nil
  state.team_start_pending = nil
  if not team then return stopped_pending end
  local session_logic = require("lazyagent.logic.session")
  for _, member in pairs(team.members) do
    if member.session_key then
      pcall(session_logic.close_session, member.session_key)
    end
  end
  state.team_runtime = nil
  return true
end

return M
