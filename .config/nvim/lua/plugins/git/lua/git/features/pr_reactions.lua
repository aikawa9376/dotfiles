local M = {}
local github = require('git.features.github')
M.types = { { '+1', '👍' }, { '-1', '👎' }, { 'laugh', '😄' }, { 'hooray', '🎉' },
  { 'confused', '😕' }, { 'heart', '❤️' }, { 'rocket', '🚀' }, { 'eyes', '👀' } }
function M.format(reactions)
  local parts = {}
  for _, item in ipairs(M.types) do
    local count = type(reactions) == 'table' and tonumber(github.scalar(reactions[item[1]])) or 0
    if count and count > 0 then parts[#parts + 1] = item[2] .. ' ' .. count end
  end
  return table.concat(parts, '  ')
end
return M
