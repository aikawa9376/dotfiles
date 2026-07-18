local M = {}

local function normalize_key(value)
  return tostring(value or ""):lower():gsub("[^%w]+", "")
end

function M.find(options, keys)
  keys = type(keys) == "table" and keys or { keys }
  for _, option in ipairs(type(options) == "table" and options or {}) do
    if type(option) == "table" then
      local candidates = {
        normalize_key(option.id),
        normalize_key(option.category),
        normalize_key(option.name),
      }
      for _, key in ipairs(keys) do
        local expected = normalize_key(key)
        if expected ~= "" and vim.tbl_contains(candidates, expected) then
          return option
        end
      end
    end
  end
  return nil
end

function M.current(options, keys)
  local option = M.find(options, keys)
  if not option or option.currentValue == nil or option.currentValue == "" then
    return nil
  end
  return option.currentValue
end

function M.preferred(options, keys, fallback)
  local current = M.current(options, keys)
  if current ~= nil then
    return current
  end
  return fallback
end

return M
