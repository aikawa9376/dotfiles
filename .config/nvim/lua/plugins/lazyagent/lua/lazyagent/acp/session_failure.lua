local M = {}

local function trim(value)
  return vim.trim(tostring(value or ""))
end

local function air_meta(carrier)
  local meta = type(carrier) == "table" and carrier._meta or nil
  local jetbrains = type(meta) == "table" and meta.jetbrains or nil
  local air = type(jetbrains) == "table" and jetbrains.air or nil
  if type(air) ~= "table" or tonumber(air.version) == nil or tonumber(air.version) < 1 then return nil end
  return air
end

function M.extract(carrier)
  local air = air_meta(carrier)
  local raw = air and air.sessionFailure or nil
  if type(raw) ~= "table" then return nil end
  local id = trim(raw.id)
  local revision = tonumber(raw.revision)
  local category = trim(raw.category)
  local severity = trim(raw.severity):lower()
  local title = trim(raw.title)
  if id == "" or not revision or revision < 1 or revision ~= math.floor(revision) or category == "" or title == "" then
    return nil
  end
  if severity ~= "warning" and severity ~= "error" then return nil end
  local actions, seen = {}, {}
  for _, action in ipairs(type(raw.actions) == "table" and raw.actions or {}) do
    action = trim(action)
    if action ~= "" and not seen[action] then
      seen[action] = true
      actions[#actions + 1] = action
    end
  end
  return {
    id = id,
    revision = math.floor(revision),
    category = category,
    severity = severity,
    title = title,
    details = trim(raw.details) ~= "" and trim(raw.details) or nil,
    actions = actions,
  }
end

function M.apply(owner, carrier)
  if type(owner) ~= "table" then return nil, "invalid owner" end
  local failure = M.extract(carrier)
  if not failure then return nil, "missing or invalid session failure" end
  owner.session_failures = type(owner.session_failures) == "table" and owner.session_failures or {}
  owner.session_failure_order = type(owner.session_failure_order) == "table" and owner.session_failure_order or {}
  local previous = owner.session_failures[failure.id]
  if previous and tonumber(previous.revision) >= failure.revision then
    return vim.deepcopy(previous), "ignored"
  end
  local status = previous and "updated" or "created"
  if not previous then owner.session_failure_order[#owner.session_failure_order + 1] = failure.id end
  owner.session_failures[failure.id] = vim.deepcopy(failure)
  owner.active_session_failure = vim.deepcopy(failure)
  return vim.deepcopy(failure), status
end

function M.resolve(owner, id)
  if type(owner) ~= "table" or type(owner.active_session_failure) ~= "table" then return false end
  if id ~= nil and tostring(owner.active_session_failure.id) ~= tostring(id) then return false end
  owner.active_session_failure = nil
  return true
end

function M.render(failure)
  if type(failure) ~= "table" then return "" end
  local lines = { failure.title }
  if failure.details then
    lines[#lines + 1] = ""
    lines[#lines + 1] = failure.details
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = string.format(
    "Category: %s · Severity: %s · Incident: %s · Revision: %d",
    tostring(failure.category or "unknown"),
    tostring(failure.severity or "error"),
    tostring(failure.id or "unknown"),
    tonumber(failure.revision) or 1
  )
  return table.concat(lines, "\n")
end

return M
