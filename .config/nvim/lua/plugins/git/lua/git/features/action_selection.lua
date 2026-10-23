-- Capture action targets independently of mutable presentation fields.
local M = {}

function M.capture(buf, row)
  local ft = vim.bo[buf].filetype
  if ft == 'gitbranch' then
    local name = (vim.b[buf].branch_map or {})[row]
    if name then
      return { kind = 'ref', name = name, ref_kind = (vim.b[buf].branch_kinds or {})[row] }
    end
  elseif ft == 'gitstatus' then
    local key = require('git.features.status_modules').key(buf, row)
    if key then return { kind = 'module', key = key } end
  end
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
  if ft == 'gitlog' or ft == 'gitstatus' then
    local hash = line and line:match('^(%x%x%x%x%x%x%x+)%s')
    if hash then return { kind = 'commit', hash = hash } end
  end
  -- File/hunk text and unrecognized targets retain strict stale-row checks.
  return { kind = 'line', value = line }
end

function M.matches(buf, row, selection)
  return vim.api.nvim_buf_is_valid(buf) and vim.deep_equal(selection, M.capture(buf, row))
end

return M
