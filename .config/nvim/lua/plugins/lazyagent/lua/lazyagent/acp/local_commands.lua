local M = {}

local ordered_names = { "config", "model", "mode", "new" }

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

function M.entries()
  local out = {}
  for _, name in ipairs(ordered_names) do
    out[#out + 1] = vim.deepcopy(commands[name])
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
