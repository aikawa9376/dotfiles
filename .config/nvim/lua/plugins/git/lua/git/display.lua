-- UI labels are separate from the full repository/object identity in the URI.
local M = {}
function M.name(buf)
  local source = vim.b[buf].git_object
  if not source then return nil end
  local revision = source.stage or source.revision or source.blob or source.object
  if revision and revision:match('^%x+$') then revision = revision:sub(1, 7) end
  local path = source.path and source.path:gsub('/+$', '')
  local name = path and path ~= '' and vim.fs.basename(path) or '[tree]'
  if not source.path then return revision end
  return name .. ' [' .. revision .. ']'
end
return M
