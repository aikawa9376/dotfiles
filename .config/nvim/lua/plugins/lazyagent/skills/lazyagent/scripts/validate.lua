local uv = vim.uv or vim.loop

local source = debug.getinfo(1, "S").source:gsub("^@", "")
source = uv.fs_realpath(source) or vim.fn.fnamemodify(source, ":p")

local function find_plugin_root(path)
  local current = vim.fn.fnamemodify(path or "", ":p")
  if vim.fn.isdirectory(current) ~= 1 then
    current = vim.fn.fnamemodify(current, ":h")
  end
  for _ = 1, 8 do
    if vim.fn.filereadable(current .. "/lua/lazyagent/teams/config.lua") == 1 then
      return current:gsub("/$", "")
    end
    local parent = vim.fn.fnamemodify(current, ":h")
    if parent == current then break end
    current = parent
  end
  return nil
end

local plugin_root = find_plugin_root(source) or find_plugin_root(vim.env.LAZYAGENTBIN)

if not plugin_root then
  io.stderr:write("Could not locate the LazyAgent plugin root from the skill or LAZYAGENTBIN\n")
  vim.cmd("cquit 1")
  return
end

vim.opt.runtimepath:prepend(plugin_root)
package.path = table.concat({
  plugin_root .. "/lua/?.lua",
  plugin_root .. "/lua/?/init.lua",
  package.path,
}, ";")

local config_path = arg and arg[1] or nil
if not config_path or config_path == "" then
  io.stderr:write("Usage: validate.lua /absolute/path/to/.lazyagent/teams.json\n")
  vim.cmd("cquit 1")
  return
end

config_path = vim.fn.fnamemodify(config_path, ":p")
local catalog, err = require("lazyagent.teams.config").load_all(config_path)
if not catalog then
  io.stderr:write(tostring(err) .. "\n")
  vim.cmd("cquit 1")
  return
end

local ids = vim.tbl_keys(catalog.teams)
table.sort(ids)
io.stdout:write(string.format(
  "Valid LazyAgent Teams config: %s (%d team%s: %s)\n",
  config_path,
  #ids,
  #ids == 1 and "" or "s",
  table.concat(ids, ", ")
))
