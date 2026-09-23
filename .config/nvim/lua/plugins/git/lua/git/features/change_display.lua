-- Shared status/commit file rows and diff statistics.
local M = {}
function M.path(entry)
  return entry.display_path or (entry.old_path and (entry.old_path .. ' -> ' .. entry.path)) or entry.path
end
function M.line(entry)
  return (entry.status == '.' and ' ' or entry.status) .. ' ' .. M.path(entry)
end
function M.statistics(entry, add_group, delete_group)
  if entry.binary then return { { ' binary', 'Comment' } } end
  local chunks = {}
  if (entry.additions or 0) > 0 or (entry.section == 'untracked' and entry.additions == 0) then
    chunks[#chunks + 1] = { ' +' .. entry.additions, add_group or 'GitSignsAdd' }
  end
  if (entry.deletions or 0) > 0 then chunks[#chunks + 1] = { ' -' .. entry.deletions, delete_group or 'GitSignsDelete' } end
  return chunks
end
return M
