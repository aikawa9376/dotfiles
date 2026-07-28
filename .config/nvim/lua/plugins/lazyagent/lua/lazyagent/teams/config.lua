local M = {}
local uv = vim.uv or vim.loop

M.project_path = ".lazyagent/teams.json"
M.global_path = "lazyagent/teams.json"
M.max_instructions_bytes = 64 * 1024

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
  if value.worktree ~= nil and type(value.worktree) ~= "boolean" and type(value.worktree) ~= "table" then
    return fail("worktree must be a boolean or object")
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
    if member.instructions_file ~= nil and type(member.instructions_file) ~= "string" then
      return fail("member '" .. id .. "'.instructions_file must be a string")
    end
    if member.model ~= nil and type(member.model) ~= "string" then
      return fail("member '" .. id .. "'.model must be a string")
    end
    if member.worktree ~= nil and type(member.worktree) ~= "boolean" and type(member.worktree) ~= "table" then
      return fail("member '" .. id .. "'.worktree must be a boolean or object")
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

local function realpath(path)
  return uv.fs_realpath(path) or vim.fn.fnamemodify(path, ":p"):gsub("/$", "")
end

local function path_within(path, root)
  path = realpath(path)
  root = realpath(root)
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function resolve_managed_path(root_dir, path, label, kind)
  if type(path) ~= "string" or path == "" then return nil, label .. " must not be empty" end
  local resolved = vim.fn.fnamemodify(path:sub(1, 1) == "/" and path or (root_dir .. "/" .. path), ":p")
    :gsub("/$", "")
  if kind == "file" and vim.fn.filereadable(resolved) ~= 1 then
    return nil, label .. " is not readable: " .. resolved
  end
  if kind == "directory" and vim.fn.isdirectory(resolved) ~= 1 then
    return nil, label .. " is not a directory: " .. resolved
  end
  if not path_within(resolved, root_dir) then
    return nil, label .. " must stay inside team root: " .. resolved
  end
  return realpath(resolved)
end

local function hydrate(config)
  for id, member in pairs(config.members) do
    if member.instructions_file and member.instructions_file ~= "" then
      if not member.instructions_file:lower():match("%.md$") then
        return nil, "member '" .. id .. "'.instructions_file must reference a Markdown file"
      end
      local path, path_err = resolve_managed_path(
        config.root_dir,
        member.instructions_file,
        "member '" .. id .. "'.instructions_file",
        "file"
      )
      if not path then return nil, path_err end
      local size = vim.fn.getfsize(path)
      if size < 0 or size > M.max_instructions_bytes then
        return nil, "member '" .. id .. "'.instructions_file exceeds 64 KiB"
      end
      local ok_read, lines = pcall(vim.fn.readfile, path)
      if not ok_read then return nil, "failed to read role instructions: " .. tostring(lines) end
      local external = vim.trim(table.concat(lines, "\n"))
      member.instructions_path = path
      member.instructions = vim.trim(table.concat(vim.tbl_filter(function(text)
        return type(text) == "string" and text ~= ""
      end, { member.instructions, external }), "\n\n"))
    end
  end
  return config
end

local function config_root(path)
  local config_path = vim.fn.fnamemodify(path, ":p")
  local config_dir = vim.fn.fnamemodify(config_path, ":h")
  return vim.fn.fnamemodify(config_dir, ":t") == ".lazyagent"
      and vim.fn.fnamemodify(config_dir, ":h")
    or config_dir
end

function M.load_all(path, opts)
  opts = opts or {}
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
  if type(decoded) ~= "table" or decoded.version ~= 1 then
    return nil, "invalid teams config: version must be 1 (" .. path .. ")"
  end
  local definitions = {}
  local default_team = decoded.default_team
  if decoded.members ~= nil then
    local single_id = tostring(decoded.id or "default")
    definitions[single_id] = decoded
    default_team = single_id
  elseif type(decoded.teams) == "table" and not is_list(decoded.teams) then
    definitions = decoded.teams
  else
    return nil, "invalid teams config: expected members or teams object (" .. path .. ")"
  end
  if default_team ~= nil and (type(default_team) ~= "string" or definitions[default_team] == nil) then
    return nil, "invalid teams config: default_team must name a configured team (" .. path .. ")"
  end

  local catalog = {
    path = vim.fn.fnamemodify(path, ":p"),
    root_dir = opts.root_dir or config_root(path),
    default_team = default_team,
    teams = {},
  }
  for id, definition in pairs(definitions) do
    if type(id) ~= "string" or not id:match("^[%w][%w_.-]*$") then
      return nil, "invalid teams config: team ids use letters, numbers, '_', '-' and '.' (" .. path .. ")"
    end
    if type(definition) ~= "table" then
      return nil, "invalid teams config: team '" .. id .. "' must be an object (" .. path .. ")"
    end
    local candidate = vim.deepcopy(definition)
    candidate.version = decoded.version
    candidate.name = candidate.name or id
    if candidate.worktree == nil then candidate.worktree = decoded.worktree end
    local config, err = M.validate(candidate)
    if not config then return nil, err .. " (" .. path .. ", team " .. id .. ")" end
    config.path = catalog.path
    config.root_dir = catalog.root_dir
    config.team_id = id
    local hydrated, hydrate_err = hydrate(config)
    if not hydrated then
      return nil, "invalid teams config: " .. hydrate_err .. " (" .. path .. ", team " .. id .. ")"
    end
    catalog.teams[id] = hydrated
  end
  if vim.tbl_count(catalog.teams) == 0 then
    return nil, "invalid teams config: teams must not be empty (" .. path .. ")"
  end
  return catalog
end

function M.select(catalog, team_id)
  if type(catalog) ~= "table" or type(catalog.teams) ~= "table" then
    return nil, "teams catalog is invalid"
  end
  local selected = team_id or catalog.default_team
  if selected and catalog.teams[selected] then return catalog.teams[selected] end
  local ids = vim.tbl_keys(catalog.teams)
  table.sort(ids)
  if #ids == 1 then return catalog.teams[ids[1]] end
  if selected then return nil, "unknown team '" .. tostring(selected) .. "'" end
  return nil, "multiple teams configured: " .. table.concat(ids, ", ")
end

function M.load(path, opts)
  local catalog, err = M.load_all(path)
  if not catalog then return nil, err end
  return M.select(catalog, opts and opts.team)
end

function M.resolve_all(start_path, opts)
  local path = M.find(start_path, opts)
  if not path then
    return nil, "no " .. M.project_path .. " found in this directory or its parents"
  end
  local root_dir = nil
  if not (opts and opts.path) then
    local global = vim.fn.fnamemodify(vim.fn.stdpath("config") .. "/" .. M.global_path, ":p")
    if vim.fn.fnamemodify(path, ":p") == global then
      root_dir = normalize_dir(start_path)
    end
  end
  local catalog, err = M.load_all(path, { root_dir = root_dir })
  if not catalog then return nil, err end
  return catalog
end

function M.resolve(start_path, opts)
  local catalog, err = M.resolve_all(start_path, opts)
  if not catalog then return nil, err end
  local config, select_err = M.select(catalog, opts and opts.team)
  if not config then return nil, select_err end
  return config
end

return M
