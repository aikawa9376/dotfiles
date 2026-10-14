-- Semantic names first. Independent drafts/views only need an instance key
-- when another buffer already owns the exact same semantic URI.
local M = {}
function M.escape(value)
  return tostring(value):gsub('[%%#?%c]', function(char) return ('%%%02X'):format(char:byte()) end)
end
function M.uri(scheme, root, target)
  return scheme .. '://' .. M.escape(root) .. '//' .. M.escape(target)
end
function M.find(name)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf) == name then return buf end
  end
end
function M.assign(buf, name)
  if buf == 0 then buf = vim.api.nvim_get_current_buf() end
  local owner = M.find(name)
  local actual = owner and owner ~= buf and (name .. '?view=' .. buf) or name
  vim.api.nvim_buf_set_name(buf, actual)
  vim.b[buf].git_buffer_uri = name
  return actual
end
function M.commit(root, hash, parent)
  return M.uri('git-commit', root, hash .. (parent and parent ~= 1 and ('/parent-' .. parent) or ''))
end
function M.parse_commit(name)
  name = name:gsub('%?view=%d+$', '')
  local root, hash, parent = name:match('^git%-commit://(.*)//(%x+)/parent%-(%d+)$')
  if not root then root, hash = name:match('^git%-commit://(.*)//(%x+)$') end
  if root then return vim.uri_decode(root), hash, tonumber(parent) end
  -- Saved quickfix/jump/session entries from the serial-based naming scheme.
  local old_root, _, old_hash = name:match('^git%-commit://(.*)/(%d+)/(%x+)$')
  return old_root, old_hash
end
return M
