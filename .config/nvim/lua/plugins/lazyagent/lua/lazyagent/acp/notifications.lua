local M = {}

local LABELS = {
  permission = "Permission required",
  elicitation = "Input required",
  completion = "Turn completed",
}

local DEFAULT_ENABLED = {
  permission = true,
  elicitation = true,
  completion = false,
}

function M.emit(config, kind, context, deps)
  config = type(config) == "table" and config or {}
  context = type(context) == "table" and context or {}
  deps = deps or {}
  if config.enabled == false
    or config[kind] == false
    or (config[kind] == nil and DEFAULT_ENABLED[kind] == false)
  then
    return false
  end
  local label = LABELS[kind] or tostring(kind)
  local agent = tostring(context.agent_name or "LazyAgent ACP")
  local detail = tostring(context.message or context.title or "")
  local message = detail ~= "" and (agent .. ": " .. detail) or agent

  if config.visual ~= false then
    local notify = deps.notify or vim.notify
    pcall(notify, message, vim.log.levels.INFO, { title = label })
  end

  local command = config.sound_command
  if type(command) == "string" and command ~= "" then command = { command } end
  if type(command) == "table" and #command > 0 then
    local jobstart = deps.jobstart or vim.fn.jobstart
    pcall(jobstart, command, { detach = true })
  end
  return true
end

return M
