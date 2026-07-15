local M = {}

local function first_location(event)
  local locations = event and event.locations or nil
  if type(locations) ~= "table" then
    return nil
  end
  if locations.path or locations.uri then
    return locations
  end
  return type(locations[1]) == "table" and locations[1] or nil
end

local function location_line(location)
  if not location then
    return nil
  end
  local direct = tonumber(location.line or location.lineNumber)
  if direct then
    return math.max(1, direct)
  end
  local start = location.range and location.range.start or nil
  local zero_based = start and tonumber(start.line) or nil
  return zero_based and math.max(1, zero_based + 1) or nil
end

local function normalize_path(session, path)
  path = tostring(path or "")
  if path == "" then
    return nil
  end
  if path:match("^file://") then
    local ok, decoded = pcall(vim.uri_to_fname, path)
    path = ok and decoded or path
  elseif not path:match("^/") then
    path = tostring(session.root_dir or session.cwd or vim.fn.getcwd()) .. "/" .. path
  end
  path = vim.fn.fnamemodify(path, ":p"):gsub("/$", "")
  local roots = {}
  for _, root in pairs({ root_dir = session.root_dir, cwd = session.cwd }) do
    if root and root ~= "" then
      roots[#roots + 1] = vim.fn.fnamemodify(root, ":p"):gsub("/$", "")
    end
  end
  for _, root in ipairs(session.additional_directories or {}) do
    roots[#roots + 1] = vim.fn.fnamemodify(root, ":p"):gsub("/$", "")
  end
  for _, root in ipairs(roots) do
    if path == root or path:sub(1, #root + 1) == root .. "/" then
      return path
    end
  end
  return nil
end

function M.resolve(session, event)
  event = type(event) == "table" and event or {}
  local location = first_location(event)
  local path = location and (location.path or location.uri) or event.path
  if not path and type(event.paths) == "table" then
    path = event.paths[1]
  end
  path = normalize_path(session or {}, path)
  if not path or vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  local line = location_line(location)
  return {
    path = path,
    line = line,
    key = path .. ":" .. tostring(line or 1),
  }
end

function M.open(session, event, opener)
  local target = M.resolve(session, event)
  if not target then
    return nil
  end
  opener(target.path, { line = target.line })
  return target
end

return M
