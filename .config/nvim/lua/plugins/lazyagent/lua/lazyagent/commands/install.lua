local M = {}

local installer = require("lazyagent.logic.installer")

local scopes = { "project", "global" }
local components = { "all", "instructions", "skills" }

local function complete(arglead, cmdline)
  local args = tostring(cmdline or ""):match("^%S+%s+(.*)$") or ""
  local choices = args:find("%s") and components or scopes
  return vim.tbl_filter(function(value) return vim.startswith(value, arglead) end, choices)
end

local function notify_result(result)
  vim.notify(string.format(
    "LazyAgentInstall: %s (%d created, %d kept)\n%s",
    result.scope,
    #result.created,
    #result.skipped,
    result.target_dir
  ), vim.log.levels.INFO)
end

local function run(scope, selected)
  local result, err = installer.install({ scope = scope, components = selected })
  if not result then
    vim.notify("LazyAgentInstall: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  notify_result(result)
end

local function select_components(scope)
  vim.ui.select(components, { prompt = "LazyAgent install contents" }, function(selected)
    if selected then run(scope, selected) end
  end)
end

function M.register(create)
  create("LazyAgentInstall", function(cmdargs)
    local args = vim.split(vim.trim(cmdargs.args or ""), "%s+", { trimempty = true })
    local scope, selected = args[1], args[2]
    if scope and selected then
      run(scope, selected)
    elseif scope then
      select_components(scope)
    else
      vim.ui.select(scopes, { prompt = "LazyAgent install scope" }, function(chosen)
        if chosen then select_components(chosen) end
      end)
    end
  end, {
    nargs = "*",
    complete = complete,
    desc = "Install LazyAgent instructions and skills for a project or globally",
  })
end

M._complete = complete

return M
