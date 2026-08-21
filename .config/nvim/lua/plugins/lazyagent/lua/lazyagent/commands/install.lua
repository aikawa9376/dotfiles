local M = {}

local installer = require("lazyagent.logic.installer")

local scopes = { "project", "global" }
local components = { "all", "instructions", "skills", "teams" }

local function complete(arglead, cmdline)
  local raw = tostring(cmdline or ""):match("^%S+%s+(.*)$") or ""
  local args = vim.split(raw, "%s+", { trimempty = true })
  local position = #args + (raw:match("%s$") and 1 or 0)
  local choices = position <= 1 and scopes or position == 2 and components
    or position == 3 and args[2] == "instructions" and installer.instruction_profiles()
    or {}
  return vim.tbl_filter(function(value) return vim.startswith(value, arglead) end, choices)
end

local function notify_result(result)
  vim.notify(string.format(
    "LazyAgentInstall: %s (%d created, %d updated, %d kept)\n%s",
    result.scope,
    #result.created,
    #result.updated,
    #result.skipped,
    result.target_dir
  ), vim.log.levels.INFO)
end

local function run(scope, selected, profile)
  local result, err = installer.install({ scope = scope, components = selected, profile = profile })
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
    local scope, selected, profile = args[1], args[2], args[3]
    if scope and selected then
      run(scope, selected, profile)
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
