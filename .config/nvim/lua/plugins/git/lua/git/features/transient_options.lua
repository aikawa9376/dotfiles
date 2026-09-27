-- Shared state and input behavior for transient argument rows.
local M = {}

local function clear_others(state, name, others)
  if type(others) == 'string' then others = { others } end
  for _, other in ipairs(others or {}) do
    if other ~= name then state[other] = nil end
  end
end

function M.flag(key, label, state, name, argument, excludes)
  return { key = key, label = argument and (label .. ' (' .. argument .. ')') or label,
    highlight_argument = argument ~= nil, keep_open = true,
    state = function() return state[name] end,
    run = function(ui)
      state[name] = not state[name]
      if state[name] then clear_others(state, name, excludes) end
      ui.render()
    end }
end

function M.exclusive_flag(key, label, state, name, other, argument)
  return M.flag(key, label, state, name, argument, other)
end

function M.value(key, label, state, name, argument, validate, excludes)
  return { key = key, keep_open = true, highlight_argument = true,
    state = function() return state[name] ~= nil end,
    marker = function(active) return active and '✓' or ' ' end,
    label = function() return label .. ' (' .. argument .. (state[name] or '') .. ')' end,
    run = function(ui)
      vim.ui.input({ prompt = label .. ' (empty to clear): ', default = state[name] or '' },
        function(value)
          if value == nil then return end
          value = vim.trim(value)
          if value ~= '' and validate and not validate(value) then return end
          state[name] = value ~= '' and value or nil
          if state[name] then clear_others(state, name, excludes) end
          ui.render()
        end)
    end }
end

function M.choices(values, label)
  return function(value)
    if vim.tbl_contains(values, value) then return true end
    vim.notify(label .. ' must be one of: ' .. table.concat(values, ', '), vim.log.levels.WARN)
    return false
  end
end

return M
