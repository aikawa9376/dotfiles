local M = {}

M.URL = "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json"

function M.decode(body)
  local ok, registry = pcall(vim.json.decode, tostring(body or ""))
  if not ok or type(registry) ~= "table" then return nil, "invalid ACP registry JSON" end
  if type(registry.agents) ~= "table" then return nil, "ACP registry agents are missing" end
  local agents = {}
  for _, agent in ipairs(registry.agents) do
    if type(agent) == "table" and agent.id and agent.name and type(agent.distribution) == "table" then
      agents[#agents + 1] = agent
    end
  end
  table.sort(agents, function(left, right) return left.name:lower() < right.name:lower() end)
  return { version = registry.version, agents = agents }
end

function M.launcher(agent, preference)
  local distribution = agent and agent.distribution or {}
  local kinds = preference and { preference } or { "npx", "uvx" }
  for _, kind in ipairs(kinds) do
    local spec = distribution[kind]
    if type(spec) == "table" and spec.package and spec.package ~= "" then
      local command = kind == "npx" and { "npx", "-y", spec.package } or { "uvx", spec.package }
      vim.list_extend(command, vim.deepcopy(spec.args or {}))
      return { kind = kind, command = command, env = vim.deepcopy(spec.env or {}) }
    end
  end
  return nil, distribution.binary and "binary distribution requires managed archive installation"
    or "no supported npx/uvx distribution"
end

local function paths()
  local dir = vim.fn.stdpath("data") .. "/lazyagent/acp/registry"
  return dir, dir .. "/installed.json", dir .. "/registry.json"
end

function M.load_installed()
  local _, path = paths()
  if vim.fn.filereadable(path) ~= 1 then return {} end
  local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  return ok and type(decoded) == "table" and decoded or {}
end

local function agent_config(record)
  return {
    acp_cmd = vim.deepcopy(record.command),
    env = vim.deepcopy(record.env or {}),
    acp = { enabled = true, view = "buffer" },
    registry = {
      id = record.id,
      version = record.version,
      distribution = record.distribution,
    },
  }
end

function M.apply_installed(target, installed)
  target = target or require("lazyagent.logic.state").opts
  if type(target) ~= "table" then return 0 end
  target.interactive_agents = target.interactive_agents or {}
  installed = installed or M.load_installed()
  local applied = 0
  for id, record in pairs(installed) do
    if type(record) == "table" and type(record.command) == "table" and not target.interactive_agents[id] then
      target.interactive_agents[id] = agent_config(record)
      applied = applied + 1
    end
  end
  return applied
end

function M.install(agent)
  local launcher, launch_err = M.launcher(agent)
  if not launcher then return nil, launch_err end
  local dir, path = paths()
  vim.fn.mkdir(dir, "p")
  local installed = M.load_installed()
  installed[agent.id] = {
    id = agent.id, name = agent.name, version = agent.version, distribution = launcher.kind,
    command = launcher.command, env = launcher.env, installed_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  }
  local ok, write_err = pcall(vim.fn.writefile, { vim.json.encode(installed) }, path)
  if not ok then return nil, write_err end
  local state = require("lazyagent.logic.state")
  state.opts.interactive_agents = state.opts.interactive_agents or {}
  state.opts.interactive_agents[agent.id] = agent_config(installed[agent.id])
  return installed[agent.id]
end

function M.fetch(done)
  local dir, _, cache_path = paths()
  vim.fn.mkdir(dir, "p")
  vim.system({ "curl", "-fsSL", "--max-time", "15", M.URL }, { text = true }, function(result)
    vim.schedule(function()
      if result.code == 0 then
        vim.fn.writefile(vim.split(result.stdout or "", "\n", { plain = true }), cache_path, "b")
        done(M.decode(result.stdout))
      elseif vim.fn.filereadable(cache_path) == 1 then
        done(M.decode(table.concat(vim.fn.readfile(cache_path), "\n")))
      else
        done(nil, vim.trim(result.stderr or "registry fetch failed"))
      end
    end)
  end)
end

function M.browse()
  M.fetch(function(registry, err)
    if not registry then vim.notify("LazyAgent ACP Registry: " .. tostring(err), vim.log.levels.ERROR); return end
    local installed = M.load_installed()
    vim.ui.select(registry.agents, {
      prompt = "ACP Registry:",
      format_item = function(agent)
        local current = installed[agent.id]
        local status = current and (current.version == agent.version and "installed" or ("update " .. current.version)) or "available"
        return string.format("%s %s [%s] — %s", agent.name, agent.version or "", status, agent.description or "")
      end,
    }, function(agent)
      if not agent then return end
      local record, install_err = M.install(agent)
      if record then
        vim.notify(string.format("LazyAgent ACP Registry: %s %s registered", record.name, record.version), vim.log.levels.INFO)
      else
        vim.notify("LazyAgent ACP Registry: " .. tostring(install_err), vim.log.levels.ERROR)
      end
    end)
  end)
  return true
end

return M
