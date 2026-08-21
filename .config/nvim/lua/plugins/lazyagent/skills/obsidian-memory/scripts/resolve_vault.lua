local config_home = vim.env.XDG_CONFIG_HOME
if not config_home or config_home == "" then
  config_home = vim.fn.expand("~/.config")
end

local config_path = vim.fs.joinpath(config_home, "nvim", "lua", "plugins", "obsidian.lua")
local ok, spec = pcall(dofile, config_path)
if not ok then
  error("failed to read Obsidian config at " .. config_path .. ": " .. tostring(spec))
end

local workspaces = spec and spec.opts and spec.opts.workspaces or nil
if type(workspaces) ~= "table" or #workspaces == 0 then
  error("Obsidian config has no opts.workspaces entries: " .. config_path)
end

local selected = workspaces[1]
for _, workspace in ipairs(workspaces) do
  if workspace.name == "main" then
    selected = workspace
    break
  end
end

if type(selected.path) ~= "string" or selected.path == "" then
  error("selected Obsidian workspace has no path: " .. config_path)
end

io.stdout:write(vim.fs.normalize(vim.fn.expand(selected.path)), "\n")
