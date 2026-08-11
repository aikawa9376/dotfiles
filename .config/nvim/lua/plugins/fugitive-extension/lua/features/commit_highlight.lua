local M = {}

local groups = {
  default = 'String',
  unpushed = '@text.danger',
  diverged = 'Constant',
  unpulled = 'Constant',
}

function M.group(state)
  return groups[state] or groups.default
end

function M.hash_set(commit_lines)
  local hashes = {}
  for _, line in ipairs(commit_lines or {}) do
    local hash = line:match('^(%x+)')
    if hash then hashes[hash] = true end
  end
  return hashes
end

return M
