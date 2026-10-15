-- Native section identities shared by fold handling and extension placement.
local M = {}
M.definitions = {
  { id = 'header', pattern = '^Head:', highlight = 'RainbowDelimiterBlue', open = true },
  { id = 'conflicted', pattern = '^Unmerged paths %(', highlight = 'RainbowDelimiterRed', open = true },
  { id = 'untracked', pattern = '^Untracked files %(', highlight = 'RainbowDelimiterOrange', open = true },
  { id = 'unstaged', pattern = '^Unstaged changes %(', highlight = 'RainbowDelimiterYellow', open = true },
  { id = 'staged', pattern = '^Staged changes %(', highlight = 'RainbowDelimiterGreen', open = true },
  { id = 'stashes', pattern = '^Stashes %(', highlight = 'RainbowDelimiterOrange' },
  { id = 'commits', pattern = '^Unpushed %[only%] %(', highlight = 'RainbowDelimiterViolet', open = true },
  { id = 'commits', pattern = '^Commits %[latest 15%+%] %(', highlight = 'RainbowDelimiterViolet', open = true },
  { id = 'unpulled', pattern = '^Unpulled from .+ %(', highlight = 'RainbowDelimiterCyan' },
  { id = 'pull_requests', pattern = '^Pull requests %(', highlight = 'RainbowDelimiterGreen' },
  { id = 'submodules', pattern = '^Submodules %(', highlight = 'RainbowDelimiterBlue' },
  { id = 'worktrees', pattern = '^Worktrees %(', highlight = 'RainbowDelimiterViolet' },
  { id = 'index_flags', pattern = '^Index flags %[local%] %(', highlight = 'RainbowDelimiterCyan', folded = true },
}
function M.match(line)
  for _, definition in ipairs(M.definitions) do
    if line:match(definition.pattern) then return definition end
  end
end
function M.valid(id)
  if id == 'top' or id == 'bottom' then return true end
  for _, definition in ipairs(M.definitions) do if definition.id == id then return true end end
  return false
end
function M.ranges(lines)
  local result = {}
  for row, line in ipairs(lines) do
    local definition = M.match(line)
    if definition then
      local last = row
      while last < #lines and lines[last + 1] ~= '' do last = last + 1 end
      result[definition.id] = { first = row, last = last }
    end
  end
  return result
end
return M
