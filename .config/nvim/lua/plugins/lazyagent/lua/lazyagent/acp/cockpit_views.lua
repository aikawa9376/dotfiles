local M = {}
local uv = vim.uv or vim.loop
local Query = require("lazyagent.acp.cockpit_query")
local Store = {}
Store.__index = Store

local function valid(view)
  if type(view) ~= "table" or view.schema_version ~= 1 or type(view.name) ~= "string"
    or vim.trim(view.name) == "" or #view.name > 200 or view.name:find("%c")
    or type(view.query) ~= "string" or #view.query > 4096 or type(view.attention_only) ~= "boolean" then
    return nil, "Invalid saved Cockpit view"
  end
  local compiled, err = Query.compile(view.query)
  return compiled and true or nil, err
end

function Store:_path(name) return self.dir .. "/" .. vim.fn.sha256(name) .. ".json" end

function Store:get(name)
  local path = self:_path(name)
  if not uv.fs_stat(path) then return nil end
  local ok, view = pcall(function() return vim.json.decode(table.concat(vim.fn.readfile(path), "\n")) end)
  if not ok then return nil, "Unreadable saved Cockpit view: " .. name end
  local accepted, err = valid(view)
  if not accepted or view.name ~= name then return nil, err or "Saved view name mismatch" end
  return view
end

function Store:list()
  if not uv.fs_stat(self.dir) then return {} end
  local scan, err = uv.fs_scandir(self.dir)
  if not scan then return nil, err end
  local views, warnings = {}, {}
  while true do
    local name, kind = uv.fs_scandir_next(scan)
    if not name then break end
    if kind == "file" and name:match("^[a-f0-9]+%.json$") then
      local ok, view = pcall(function() return vim.json.decode(table.concat(vim.fn.readfile(self.dir .. "/" .. name), "\n")) end)
      local accepted = ok and valid(view)
      if accepted and name == vim.fn.sha256(view.name) .. ".json" then views[#views + 1] = view
      else warnings[#warnings + 1] = name end
    end
  end
  table.sort(views, function(a, b) return a.name < b.name end)
  return views, #warnings > 0 and ("Skipped invalid saved views: " .. table.concat(warnings, ", ")) or nil
end

-- Each name owns a separate file. Atomic replacement never rewrites other views.
-- Explicit overwrites use last-writer-wins semantics between editors.
function Store:save(name, query, attention_only)
  local view = { schema_version = 1, name = vim.trim(tostring(name or "")), query = query,
    attention_only = attention_only == true }
  local accepted, err = valid(view)
  if not accepted then return nil, err end
  local ok, failure = pcall(function()
    vim.fn.mkdir(self.dir, "p", 448)
    local path = self:_path(view.name)
    local temporary = path .. ".tmp-" .. vim.fn.getpid() .. "-" .. tostring(uv.hrtime())
    local fd, open_err = uv.fs_open(temporary, "wx", 384)
    if not fd then error(open_err) end
    local payload, offset = vim.json.encode(view), 0
    while offset < #payload do
      local written, write_err = uv.fs_write(fd, payload:sub(offset + 1), offset)
      if not written or written <= 0 then uv.fs_close(fd); uv.fs_unlink(temporary); error(write_err or "Short view write") end
      offset = offset + written
    end
    uv.fs_close(fd)
    local renamed, rename_err = uv.fs_rename(temporary, path)
    if not renamed then uv.fs_unlink(temporary); error(rename_err) end
  end)
  return ok and view or nil, not ok and tostring(failure) or nil
end

function Store:delete(name)
  local deleted, err = uv.fs_unlink(self:_path(name))
  return deleted, err
end

function M.new(opts)
  opts = opts or {}
  return setmetatable({ dir = opts.dir or (vim.fn.stdpath("cache") .. "/lazyagent/acp/cockpit-views") }, Store)
end
return M
