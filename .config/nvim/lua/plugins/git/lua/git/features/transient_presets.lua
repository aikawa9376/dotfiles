-- Transient argument state is scoped by worktree and operation, never by buffer.
local M = {}
local session, defaults = {}, {}
local loaded, disk
local function path() return vim.fn.stdpath('state') .. '/git-ui/transient-presets.json' end
local function data()
  if loaded then return disk end
  loaded = true
  local ok, value = pcall(function() return vim.json.decode(table.concat(vim.fn.readfile(path()), '\n')) end)
  disk = ok and type(value) == 'table' and value.version == 1 and value or { version = 1 }
  disk.global = type(disk.global) == 'table' and disk.global or {}
  disk.repositories = type(disk.repositories) == 'table' and disk.repositories or {}
  disk.history = type(disk.history) == 'table' and disk.history or {}
  return disk
end
local function write()
  local p = path()
  vim.fn.mkdir(vim.fs.dirname(p), 'p')
  local temp = p .. '.tmp'
  local ok, err = pcall(function()
    assert(vim.fn.writefile({ vim.json.encode(data()) }, temp) == 0, 'Could not write presets')
    assert(vim.uv.fs_rename(temp, p))
  end)
  if not ok then vim.notify(tostring(err), vim.log.levels.ERROR) end
  return ok
end

function M.bind(spec, root)
  if not root or spec.kind == 'root' then return end
  local fields, default = {}, {}
  for _, group in ipairs(spec.groups or {}) do
    for _, action in ipairs(group.actions) do
      local o = action.option
      if o then fields[o.name] = o; default[o.name] = o.state[o.name] end
    end
  end
  if not next(fields) then return end
  local key = root .. '\0' .. spec.kind
  defaults[key] = defaults[key] or vim.deepcopy(default)
  local store = data()
  local repo = type(store.repositories[root]) == 'table' and store.repositories[root] or {}
  local saved = repo[spec.kind] or store.global[spec.kind]
  if type(saved) ~= 'table' then saved = nil end
  local function apply(values)
    for name, o in pairs(fields) do
      local value = values[name]
      if value ~= nil and type(value) ~= o.type then value = nil end
      if value ~= nil and o.validate and not o.validate(value) then value = nil end
      o.state[name] = value
    end
    -- Honor the same exclusion rules as interactive flag changes.
    for _, name in ipairs(vim.fn.sort(vim.tbl_keys(fields))) do
      local o = fields[name]
      if o.state[name] then
        local excludes = type(o.excludes) == 'string' and { o.excludes } or o.excludes or {}
        for _, other in ipairs(excludes) do if other ~= name then o.state[other] = nil end end
      end
    end
  end
  apply(session[key] or saved or defaults[key])
  local function snapshot()
    local result = {}
    for name, o in pairs(fields) do result[name] = o.state[name] end
    return result
  end
  local function remember(history)
    if not history then session[key] = snapshot() end
    if history then
      if type(store.history[root]) ~= 'table' then store.history[root] = {} end
      local rows = store.history[root][spec.kind]
      if type(rows) ~= 'table' or not vim.islist(rows) then rows = {} end
      local value = snapshot()
      rows = vim.tbl_filter(function(row) return not vim.deep_equal(row, value) end, rows)
      table.insert(rows, 1, value)
      while #rows > 20 do table.remove(rows) end
      store.history[root][spec.kind] = rows
      write()
    end
  end
  local function label(values)
    local parts = {}
    for _, name in ipairs(vim.fn.sort(vim.tbl_keys(values))) do
      parts[#parts + 1] = name .. '=' .. tostring(values[name])
    end
    return #parts > 0 and table.concat(parts, ', ') or '(no arguments)'
  end
  local actions = {
    { key = '<C-w>', label = 'Save arguments for this session', keep_open = true, run = function(ui)
      remember(false); ui.render()
    end },
    { key = '<C-s>', label = 'Save arguments for all repositories', keep_open = true, run = function(ui)
      store.global[spec.kind] = snapshot(); remember(false); write(); ui.render()
    end },
    { key = '<C-r>', label = 'Save arguments for this worktree', keep_open = true, run = function(ui)
      if type(store.repositories[root]) ~= 'table' then store.repositories[root] = {} end
      store.repositories[root][spec.kind] = snapshot(); remember(false); write(); ui.render()
    end },
    { key = '<C-d>', label = 'Clear saved arguments and restore defaults', keep_open = true, run = function(ui)
      store.global[spec.kind] = nil
      if type(store.repositories[root]) == 'table' then store.repositories[root][spec.kind] = nil end
      apply(defaults[key]); remember(false); write(); ui.render()
    end },
    { key = '<C-h>', label = 'Recall argument history', keep_open = true, run = function(ui)
      local history = type(store.history[root]) == 'table' and store.history[root] or {}
      local rows = history[spec.kind]
      if type(rows) ~= 'table' or not vim.islist(rows) then rows = {} end
      rows = vim.tbl_filter(function(row) return type(row) == 'table' end, rows)
      vim.ui.select(rows, { prompt = 'Argument history: ', format_item = label }, function(value)
        if value then apply(value); remember(false); ui.render() end
      end)
    end },
  }
  spec.groups[#spec.groups + 1] = { title = 'Argument presets', actions = actions }
  return remember
end
return M
