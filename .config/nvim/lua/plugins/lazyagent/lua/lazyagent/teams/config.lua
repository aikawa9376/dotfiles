local M = {}

M.project_path = ".lazyagent/teams.json"
M.global_path = "lazyagent/teams.json"

local function is_list(value)
  if type(value) ~= "table" then
    return false
  end
  if vim.islist then
    return vim.islist(value)
  end
  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      return false
    end
    count = count + 1
  end
  for index = 1, count do
    if rawget(value, index) == nil then
      return false
    end
  end
  return true
end

local function normalize_dir(path)
  path = vim.fn.fnamemodify(path or vim.fn.getcwd(), ":p")
  if vim.fn.isdirectory(path) ~= 1 then
    path = vim.fn.fnamemodify(path, ":h")
  end
  return path:gsub("[/\\]+$", "")
end

local function readable(path)
  return type(path) == "string" and path ~= "" and vim.fn.filereadable(path) == 1
end

function M.find(start_path, opts)
  opts = opts or {}
  if opts.path and opts.path ~= "" then
    local explicit = vim.fn.fnamemodify(opts.path, ":p")
    return readable(explicit) and explicit or nil
  end

  local dir = normalize_dir(start_path)
  while dir ~= "" do
    local candidate = dir .. "/" .. M.project_path
    if readable(candidate) then
      return candidate
    end
    local parent = vim.fn.fnamemodify(dir, ":h"):gsub("[/\\]+$", "")
    if parent == dir or parent == "" then
      break
    end
    dir = parent
  end

  if opts.include_global ~= false then
    local global = vim.fn.stdpath("config") .. "/" .. M.global_path
    if readable(global) then
      return global
    end
  end
  return nil
end

local function fail(message)
  return nil, "invalid teams config: " .. message
end

function M.validate(value)
  if type(value) ~= "table" then
    return fail("root must be an object")
  end
  if value.version ~= 1 then
    return fail("version must be 1")
  end
  if type(value.name) ~= "string" or vim.trim(value.name) == "" then
    return fail("name must be a non-empty string")
  end
  if type(value.lead) ~= "string" or vim.trim(value.lead) == "" then
    return fail("lead must name a member")
  end
  if type(value.members) ~= "table" or is_list(value.members) then
    return fail("members must be an object keyed by member id")
  end
  if type(value.members[value.lead]) ~= "table" then
    return fail("lead '" .. tostring(value.lead) .. "' is not present in members")
  end

  local parent = {}
  local member_count = 0
  for id, member in pairs(value.members) do
    member_count = member_count + 1
    if type(id) ~= "string" or not id:match("^[%w][%w_.-]*$") then
      return fail("member ids may only contain letters, numbers, '_', '-' and '.'")
    end
    if type(member) ~= "table" then
      return fail("member '" .. id .. "' must be an object")
    end
    if type(member.agent) ~= "string" or vim.trim(member.agent) == "" then
      return fail("member '" .. id .. "' must declare an agent")
    end
    if member.role ~= nil and type(member.role) ~= "string" then
      return fail("member '" .. id .. "'.role must be a string")
    end
    if member.instructions ~= nil and type(member.instructions) ~= "string" then
      return fail("member '" .. id .. "'.instructions must be a string")
    end
    local reports = member.reports or {}
    if not is_list(reports) then
      return fail("member '" .. id .. "'.reports must be an array")
    end
    for _, child in ipairs(reports) do
      if type(child) ~= "string" or type(value.members[child]) ~= "table" then
        return fail("member '" .. id .. "' references unknown report '" .. tostring(child) .. "'")
      end
      if child == id then
        return fail("member '" .. id .. "' cannot report to itself")
      end
      if parent[child] then
        return fail("member '" .. child .. "' reports to both '" .. parent[child] .. "' and '" .. id .. "'")
      end
      parent[child] = id
    end
  end
  if member_count == 0 then
    return fail("members must not be empty")
  end
  if parent[value.lead] then
    return fail("lead '" .. value.lead .. "' cannot report to another member")
  end

  local seen = {}
  local visiting = {}
  local function visit(id)
    if visiting[id] then
      return nil, "cycle detected at member '" .. id .. "'"
    end
    if seen[id] then
      return true
    end
    visiting[id] = true
    for _, child in ipairs(value.members[id].reports or {}) do
      local ok, err = visit(child)
      if not ok then return nil, err end
    end
    visiting[id] = nil
    seen[id] = true
    return true
  end
  local ok, graph_err = visit(value.lead)
  if not ok then
    return fail(graph_err)
  end
  for id in pairs(value.members) do
    if not seen[id] then
      return fail("member '" .. id .. "' is not reachable from lead '" .. value.lead .. "'")
    end
  end

  local normalized = vim.deepcopy(value)
  normalized.path = nil
  normalized.members = normalized.members or {}
  for id, member in pairs(normalized.members) do
    member.id = id
    member.role = vim.trim(member.role or id)
    member.instructions = vim.trim(member.instructions or "")
    member.reports = vim.deepcopy(member.reports or {})
    member.manager = parent[id]
  end
  return normalized
end

function M.load(path)
  if not readable(path) then
    return nil, "teams config not found: " .. tostring(path)
  end
  local ok_read, lines = pcall(vim.fn.readfile, path)
  if not ok_read then
    return nil, "failed to read teams config: " .. tostring(lines)
  end
  local ok_decode, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not ok_decode then
    return nil, "invalid JSON in " .. path .. ": " .. tostring(decoded)
  end
  local config, err = M.validate(decoded)
  if not config then
    return nil, err .. " (" .. path .. ")"
  end
  config.path = vim.fn.fnamemodify(path, ":p")
  local config_dir = vim.fn.fnamemodify(config.path, ":h")
  config.root_dir = vim.fn.fnamemodify(config_dir, ":t") == ".lazyagent"
      and vim.fn.fnamemodify(config_dir, ":h")
    or config_dir
  return config
end

function M.resolve(start_path, opts)
  local path = M.find(start_path, opts)
  if not path then
    return nil, "no " .. M.project_path .. " found in this directory or its parents"
  end
  local config, err = M.load(path)
  if not config then return nil, err end
  if not (opts and opts.path) then
    local global = vim.fn.fnamemodify(vim.fn.stdpath("config") .. "/" .. M.global_path, ":p")
    if vim.fn.fnamemodify(path, ":p") == global then
      config.root_dir = normalize_dir(start_path)
    end
  end
  return config
end

return M
