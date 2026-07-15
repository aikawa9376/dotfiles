local M = {}

local function base_dir(opts)
  return (opts and opts.base_dir) or (vim.fn.stdpath("data") .. "/lazyagent/acp/permissions")
end

local function project_root(session)
  return tostring((session and (session.root_dir or session.cwd)) or vim.fn.getcwd())
end

local function rule_path(scope, session, opts)
  local base = base_dir(opts)
  if scope == "global" then return base .. "/global.json" end
  if scope == "project" then return base .. "/projects/" .. vim.fn.sha256(project_root(session)) .. ".json" end
end

local function read_rules(path)
  if not path or vim.fn.filereadable(path) ~= 1 then return {} end
  local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  return ok and type(decoded) == "table" and decoded or {}
end

local function rule_key(rule)
  return table.concat({ rule.agent or "", rule.tool or "", rule.kind or "", rule.path or "", rule.title or "" }, "\0")
end

function M.rule(session, tool, option, scope, path)
  local tool_name = tostring(tool and (tool.toolName or tool.name) or "")
  local title = tostring(tool and tool.title or "")
  local rule = {
    label = string.format("remembered %s permission", scope),
    scope = scope,
    action = option and option.kind or nil,
    agent = tostring((session and (session.provider_id or session.agent_name)) or ""),
    tool = tool_name ~= "" and tool_name or nil,
    kind = tool and tool.kind or nil,
    path = path,
  }
  if not rule.tool and not rule.kind and not rule.path and title ~= "" then rule.title = title end
  return rule
end

local function option_for(options, preferred)
  for _, option in ipairs(options or {}) do
    if option.kind == preferred then return option end
  end
  local polarity = preferred:match("^(allow)") or preferred:match("^(reject)")
  for _, option in ipairs(options or {}) do
    if polarity and tostring(option.kind or ""):match("^" .. polarity) then return option end
  end
end

function M.choices(options)
  local labels, choices = {}, {}
  for _, option in ipairs(options or {}) do
    local scope = tostring(option.kind or ""):match("_once$") and "once" or "agent"
    labels[#labels + 1] = string.format("%s [%s] — %s", option.name or option.optionId or "Option",
      option.kind or "option", scope == "agent" and "agent-managed" or scope)
    choices[#choices + 1] = { option = option, scope = scope }
  end
  for _, learned in ipairs({
    { label = "Allow", option = option_for(options, "allow_once") },
    { label = "Reject", option = option_for(options, "reject_once") },
  }) do
    if learned.option then
      for _, scope in ipairs({ "session", "project", "global" }) do
        labels[#labels + 1] = string.format("%s — remember for %s", learned.label, scope)
        choices[#choices + 1] = { option = learned.option, scope = scope }
      end
    end
  end
  return labels, choices
end

function M.remember(session, scope, rule, opts)
  if scope == "session" then
    session.learned_permission_rules = session.learned_permission_rules or {}
    local key = rule_key(rule)
    for index, existing in ipairs(session.learned_permission_rules) do
      if rule_key(existing) == key then session.learned_permission_rules[index] = vim.deepcopy(rule); return true end
    end
    table.insert(session.learned_permission_rules, vim.deepcopy(rule))
    return true
  end
  local path = rule_path(scope, session, opts)
  if not path then return nil, "unsupported permission scope: " .. tostring(scope) end
  local rules = read_rules(path)
  local key, replaced = rule_key(rule), false
  for index, existing in ipairs(rules) do
    if rule_key(existing) == key then rules[index] = vim.deepcopy(rule); replaced = true; break end
  end
  if not replaced then rules[#rules + 1] = vim.deepcopy(rule) end
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local ok, err = pcall(vim.fn.writefile, { vim.json.encode(rules) }, path)
  if ok then pcall(vim.uv.fs_chmod, path, 384) end
  return ok and true or nil, ok and nil or err
end

function M.rules(session, opts)
  local rules = vim.deepcopy((session and session.learned_permission_rules) or {})
  vim.list_extend(rules, read_rules(rule_path("project", session, opts)))
  vim.list_extend(rules, read_rules(rule_path("global", session, opts)))
  return rules
end

function M.audit(session, tool, outcome, metadata, opts)
  metadata = metadata or {}
  local option_id = type(outcome) == "table" and outcome.optionId or nil
  local record = {
    timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    agent = session and session.agent_name or nil,
    provider = session and session.provider_id or nil,
    thread_id = session and session.thread_id or nil,
    project = project_root(session),
    tool_call_id = tool and tool.toolCallId or nil,
    tool = tool and (tool.toolName or tool.name) or nil,
    kind = tool and tool.kind or nil,
    path = metadata.path,
    outcome = type(outcome) == "table" and outcome.outcome or "cancelled",
    option_id = option_id,
    source = metadata.source or "manual",
    scope = metadata.scope or "once",
    rule = metadata.rule,
  }
  local path = base_dir(opts) .. "/audit.jsonl"
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local ok, err = pcall(vim.fn.writefile, { vim.json.encode(record) }, path, "a")
  if ok then pcall(vim.uv.fs_chmod, path, 384) end
  return ok and path or nil, ok and nil or err
end

function M.audit_path(opts)
  return base_dir(opts) .. "/audit.jsonl"
end

function M.open_audit(opts)
  if not opts then
    local ok, state = pcall(require, "lazyagent.logic.state")
    local acp = ok and state.opts and state.opts.acp or nil
    local permissions = type(acp) == "table" and acp.permissions or nil
    opts = { base_dir = type(permissions) == "table" and permissions.dir or nil }
  end
  local path = M.audit_path(opts)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  if vim.fn.filereadable(path) ~= 1 then vim.fn.writefile({}, path) end
  pcall(vim.uv.fs_chmod, path, 384)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  vim.bo.filetype = "jsonl"
  return path
end

return M
