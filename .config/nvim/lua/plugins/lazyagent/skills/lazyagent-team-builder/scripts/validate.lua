local uv = vim.uv or vim.loop

local source = debug.getinfo(1, "S").source:gsub("^@", "")
source = uv.fs_realpath(source) or vim.fn.fnamemodify(source, ":p")
local plugin_root = source:match("^(.*)/skills/lazyagent%-team%-builder/scripts/validate%.lua$")

if not plugin_root then
  io.stderr:write("Could not locate the LazyAgent plugin root from: " .. source .. "\n")
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
