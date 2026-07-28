local M = {}

local state = require("lazyagent.logic.state")
local config_loader = require("lazyagent.teams.config")
local agent_logic = require("lazyagent.logic.agent")
local backend_logic = require("lazyagent.logic.backend")
local mcp_integration = require("lazyagent.integrations.mcp")
local Worktree = require("lazyagent.acp.worktree")

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

local function safe_name(value)
  local name = tostring(value or ""):lower():gsub("[^%w._-]", "-"):gsub("%-+", "-")
  name = name:gsub("^%-+", ""):gsub("%-+$", "")
  return name ~= "" and name or "team"
end

local function set_member_status(team, role_id, status, err)
  local member = team and team.members and team.members[role_id] or nil
  if not member then return end
  member.status = status
  member.error = err
  if member.session_key and state.sessions and state.sessions[member.session_key] then
    local session_team = state.sessions[member.session_key].lazyagent_team or {}
    session_team.status = status
    session_team.error = err
    state.sessions[member.session_key].lazyagent_team = session_team
  end
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

local function worktree_policy(team, role_id)
  local member = team.config.members[role_id]
  local value = member.worktree
  if value == nil then value = team.config.worktree end
  if value == nil or value == false then return { enabled = false } end
  if value == true then return { enabled = true } end
  local policy = vim.deepcopy(value)
  if policy.enabled == nil then policy.enabled = true end
  return policy
end

local function ensure_member_worktree(team, role_id)
  local runtime_member = team.members[role_id]
  if runtime_member.worktree then return runtime_member.worktree end
  local policy = worktree_policy(team, role_id)
  if policy.enabled ~= true then return nil end

  local instance = team.id:gsub("%-", ""):sub(1, 8)
  local team_name = safe_name(team.config.team_id or team.config.name)
  local role_name = safe_name(role_id)
  local branch = tostring(policy.branch or ("lazyagent/" .. team_name .. "/" .. role_name .. "/" .. instance))
  local path = policy.path
  if type(path) == "string" and path ~= "" then
    path = path:gsub("{team}", team_name):gsub("{role}", role_name):gsub("{id}", instance)
    if path:sub(1, 1) ~= "/" then
      path = vim.fn.fnamemodify(team.config.root_dir, ":h") .. "/" .. path
    end
  else
    local cache = (state.opts.cache and state.opts.cache.dir) or (vim.fn.stdpath("cache") .. "/lazyagent")
    path = table.concat({ cache, "teams", "worktrees", safe_name(vim.fn.fnamemodify(team.config.root_dir, ":t")),
      team_name, role_name .. "-" .. instance }, "/")
  end
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local metadata, err = Worktree.create({
    root = team.config.root_dir,
    path = path,
    branch = branch,
    base = policy.base or "HEAD",
    timeout_ms = policy.timeout_ms,
  })
  if not metadata then return nil, err end
  runtime_member.worktree = metadata
  return metadata
end

local function build_member_config(team, role_id)
  local member = team.config.members[role_id]
  local base = agent_logic.get_interactive_agent(member.agent)
  if not base then
    return nil, "agent '" .. member.agent .. "' is not configured"
  end
  local worktree, worktree_err = ensure_member_worktree(team, role_id)
  if worktree_err then return nil, "worktree: " .. worktree_err end
  local root_dir = worktree and worktree.worktree_path or team.config.root_dir
  local acp = type(base.acp) == "table" and vim.deepcopy(base.acp) or {}
  acp.enabled = true
  if member.model and member.model ~= "" then acp.initial_model = member.model end
  local team_metadata = {
    instance_id = team.id,
    team_id = team.config.team_id,
    name = team.config.name,
    role_id = role_id,
    role = member.role,
    manager = member.manager,
    lead = role_id == team.config.lead,
  }
  local thread_metadata = vim.tbl_deep_extend("force", {}, worktree or {}, {
    lazyagent_team = team_metadata,
  })
  local cfg = vim.tbl_deep_extend("force", vim.deepcopy(base), {
    acp = acp,
    acp_thread_id = team.members[role_id].thread_id,
    acp_thread_title = string.format("%s · %s", team.config.name, member.role),
    acp_thread_metadata = thread_metadata,
    root_dir = root_dir,
    cwd = root_dir,
    stay_hidden = role_id ~= team.config.lead,
    lazyagent_team = {
      id = team.id,
      team_id = team.config.team_id,
      name = team.config.name,
      role_id = role_id,
      role = member.role,
      status = team.members[role_id].status,
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
  set_member_status(team, role_id, "starting")
  local function fail(message)
    set_member_status(team, role_id, "failed", message)
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
    set_member_status(team, role_id, "running")
    if state.sessions and state.sessions[session_key] then
      state.sessions[session_key].lazyagent_team = vim.tbl_extend(
        "force",
        state.sessions[session_key].lazyagent_team or {},
        {
          id = team.id,
          team_id = team.config.team_id,
          name = team.config.name,
          role_id = role_id,
          role = team.config.members[role_id].role,
          status = "running",
        }
      )
    end
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
  set_member_status(team, from, "reported")
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
      model = config_member.model,
      worktree_path = runtime_member.worktree and runtime_member.worktree.worktree_path or nil,
    }
  end
  table.sort(members, function(a, b) return a.id < b.id end)
  return {
    active = true,
    id = team.id,
    name = team.config.name,
    team_id = team.config.team_id,
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
  local policy = config.worktree
  if policy == true or (type(policy) == "table" and policy.enabled ~= false) then
    if vim.fn.system({ "git", "-C", config.root_dir, "rev-parse", "--show-toplevel" }) == "" or vim.v.shell_error ~= 0 then
      return nil, "team worktree requires a Git repository: " .. config.root_dir
    end
  end
  return true
end

local function source_path(opts)
  local source = opts and opts.start_path or nil
  if not source or source == "" then
    local current = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
    source = current ~= "" and current or vim.fn.getcwd()
  end
  return source
end

local function catalog_for(opts)
  opts = opts or {}
  local teams_opts = (state.opts and state.opts.teams) or {}
  return config_loader.resolve_all(source_path(opts), { path = opts.path or teams_opts.path })
end

function M.team_names(opts)
  local catalog = catalog_for(opts or {})
  if not catalog then return {} end
  local ids = vim.tbl_keys(catalog.teams)
  table.sort(ids)
  return ids
end

function M.select_team(team_id, opts, callback)
  opts = opts or {}
  callback = callback or function() end
  local catalog, err = catalog_for(opts)
  if not catalog then callback(nil, err) return nil, err end
  local ids = vim.tbl_keys(catalog.teams)
  table.sort(ids)
  local function select(id)
    if not id or not catalog.teams[id] then
      callback(nil, id and ("unknown team '" .. tostring(id) .. "'") or "team selection cancelled")
      return
    end
    state.team_selections = state.team_selections or {}
    state.team_selections[catalog.path] = id
    callback(id, nil, catalog.teams[id])
  end
  if team_id and team_id ~= "" then
    select(team_id)
    return true
  end
  vim.ui.select(ids, {
    prompt = "Choose LazyAgent team:",
    format_item = function(id) return string.format("%s · %s", id, catalog.teams[id].name) end,
  }, select)
  return true
end

function M.start(request, opts)
  opts = opts or {}
  request = vim.trim(tostring(request or ""))
  if request == "" then
    return nil, "request must not be empty"
  end
  local teams_opts = (state.opts and state.opts.teams) or {}
  if teams_opts.enabled == false then
    return nil, "Teams is disabled by teams.enabled = false"
  end
  local catalog, catalog_err = catalog_for(opts)
  if not catalog then return nil, catalog_err end
  local selected = opts.team
    or (state.team_selections and state.team_selections[catalog.path])
    or catalog.default_team
  local config, config_err = config_loader.select(catalog, selected)
  if not config and not selected and vim.tbl_count(catalog.teams) > 1 then
    M.select_team(nil, opts, function(choice, select_err)
      if select_err then
        if select_err ~= "team selection cancelled" then
          vim.notify("LazyAgentTeam: " .. select_err, vim.log.levels.ERROR)
        end
        return
      end
      M.start(request, vim.tbl_extend("force", {}, opts, { team = choice, path = catalog.path }))
    end)
    return { selecting = true, catalog = catalog }
  end
  if not config then return nil, config_err end
  local ready, preflight_err = preflight(config)
  if not ready then return nil, preflight_err end

  if active() then
    if active().config.path ~= config.path or active().config.team_id ~= config.team_id then
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
