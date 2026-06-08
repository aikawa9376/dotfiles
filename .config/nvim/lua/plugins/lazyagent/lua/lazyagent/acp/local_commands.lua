local M = {}

local ordered_names = { "config", "model", "mode", "resources", "capabilities", "doctor", "context", "tools", "new" }

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
  doctor = {
    name = "doctor",
    label = "/doctor",
    desc = "Open ACP health diagnostics for this session.",
    doc = "Open a local ACP doctor report with provider, runtime, permission, context, and tool state.",
  },
  context = {
    name = "context",
    label = "/context",
    desc = "Open ACP context budget details for this session.",
    doc = "Open a local ACP context budget report with usage, transcript, compaction, and carryover state.",
  },
  tools = {
    name = "tools",
    label = "/tools",
    desc = "Open ACP tool review for this session.",
    doc = "Open a local ACP tool review with statuses, touched paths, and output sizes.",
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

local function session_config_options(session)
  if not session then
    return nil
  end
  if type(session.config_options) == "table" then
    return session.config_options
  end
  if type(session.acp_config_options) == "table" then
    return session.acp_config_options
  end
  return nil
end

local function normalize_option_type(option)
  return tostring(option and option.type or ""):lower():gsub("[^%w]+", "")
end

local function is_pickable_option(option)
  if type(option) ~= "table" then
    return false
  end

  local option_type = normalize_option_type(option)
  if (option_type == "select" or option_type == "multiselect")
    and type(option.options) == "table"
    and #option.options > 0
  then
    return true
  end

  if option_type == "boolean" or option_type == "bool" or option_type == "toggle" then
    return true
  end

  return false
end

local function has_select_option(session, expected)
  local options = session_config_options(session)
  if type(options) ~= "table" then
    return false
  end
  for _, option in ipairs(options) do
    if is_pickable_option(option)
      and normalize_option_type(option) == "select"
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
  local options = session_config_options(session)
  if type(options) ~= "table" then
    return false
  end
  for _, option in ipairs(options) do
    if is_pickable_option(option) then
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
      or (session.acp_transcript_path and session.acp_transcript_path ~= "")
  end
  if name == "capabilities" then
    return true
  end
  if name == "doctor" then
    return true
  end
  if name == "context" then
    return true
  end
  if name == "tools" then
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
    return "This ACP session does not expose any selectable or toggleable options."
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

function M.merged_entries(session, advertised)
  local out = {}
  local seen = {}

  for _, command in ipairs(advertised or session and (session.available_commands or session.acp_available_commands) or {}) do
    if type(command) == "table" and command.label and command.label ~= "" and not seen[command.label] then
      seen[command.label] = true
      out[#out + 1] = vim.deepcopy(command)
    end
  end

  for _, command in ipairs(M.entries(session)) do
    if type(command) == "table" and command.label and command.label ~= "" and not seen[command.label] then
      seen[command.label] = true
      out[#out + 1] = vim.deepcopy(command)
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
