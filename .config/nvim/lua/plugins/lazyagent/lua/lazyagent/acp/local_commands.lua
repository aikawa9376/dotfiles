local M = {}

local ordered_names = { "config", "model", "mode", "resources", "capabilities", "new" }

local commands = {
  config = {
    name = "config",
    label = "/config",
    desc = "Open a local ACP config picker for this session.",
    doc = "Open a local ACP config picker for the active session.",
  },
  model = {
    name = "model",
    label = "/model",
    desc = "Open a local ACP model picker.",
    doc = "Open a local ACP model picker instead of sending `/model` as plain text.",
  },
  mode = {
    name = "mode",
    label = "/mode",
    desc = "Open a local ACP mode picker.",
    doc = "Open a local ACP mode picker instead of sending `/mode` as plain text.",
  },
  resources = {
    name = "resources",
    label = "/resources",
    desc = "Browse ACP resource references for this session.",
    doc = "Open a local ACP resource browser and insert a reference into the current scratch buffer.",
  },
  capabilities = {
    name = "capabilities",
    label = "/capabilities",
    desc = "Show ACP capability summary for this session.",
    doc = "Show ACP capabilities, config options, and local actions for the active session.",
  },
  new = {
    name = "new",
    label = "/new",
    desc = "Restart the ACP session with a fresh conversation.",
    doc = "Restart the ACP session with a fresh conversation.",
  },
}

local function trim(text)
  return tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function has_select_option(session, expected)
  if not session or type(session.config_options) ~= "table" then
    return false
  end
  for _, option in ipairs(session.config_options) do
    if type(option) == "table"
      and option.type == "select"
      and type(option.options) == "table"
      and #option.options > 0
    then
      local key = tostring(option.category or option.id or option.name or ""):lower()
      if key == expected then
        return true
      end
    end
  end
  return false
end

local function has_any_config(session)
  if not session or type(session.config_options) ~= "table" then
    return false
  end
  for _, option in ipairs(session.config_options) do
    if type(option) == "table"
      and option.type == "select"
      and type(option.options) == "table"
      and #option.options > 0
    then
      return true
    end
  end
  return false
end

function M.is_available(name, session)
  if not session then
    return true
  end
  if name == "config" then
    return has_any_config(session)
  end
  if name == "model" then
    return has_select_option(session, "model")
  end
  if name == "mode" then
    return has_select_option(session, "mode")
  end
  if name == "resources" then
    return (session.root_dir and session.root_dir ~= "")
      or (session.cwd and session.cwd ~= "")
      or (session.transcript_path and session.transcript_path ~= "")
  end
  if name == "capabilities" then
    return true
  end
  if name == "new" then
    return true
  end
  return commands[name] ~= nil
end

function M.unavailable_reason(name, session)
  if M.is_available(name, session) then
    return nil
  end
  if name == "config" then
    return "This ACP session does not expose any configurable options."
  end
  if name == "model" then
    return "This ACP session does not expose any model selector."
  end
  if name == "mode" then
    return "This ACP session does not expose any mode selector."
  end
  if name == "resources" then
    return "No ACP resource references are available for this session yet."
  end
  return "This ACP action is not available for the current session."
end

function M.entries(session)
  local out = {}
  for _, name in ipairs(ordered_names) do
    if M.is_available(name, session) then
      out[#out + 1] = vim.deepcopy(commands[name])
    end
  end
  return out
end

function M.parse(prompt)
  local normalized = trim(prompt)
  if normalized == "" then
    return nil
  end

  local name, args = normalized:match("^/([%w_-]+)%s*(.*)$")
  local command = name and commands[name] or nil
  if not command then
    return nil
  end

  return vim.deepcopy(command), args or "", normalized
end

return M
