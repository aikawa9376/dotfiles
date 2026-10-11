local M = {}
function M.format(target, missing)
  local scalar = require('git.features.github').scalar
  local line, first = scalar(target.line), scalar(target.start_line)
  if not line then return target.path .. ' (' .. (missing or 'file') .. ')' end
  local range = first and first ~= line and ('L' .. first .. '-L' .. line) or ('L' .. line)
  return target.path .. ':' .. range .. ' (' .. (scalar(target.side) or 'RIGHT') .. ')'
end
return M
