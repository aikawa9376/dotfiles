local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
vim.opt.rtp:prepend(plugin)
vim.cmd('syntax enable')
local lines = {
  'Head: main',
  'Upstream: origin/main (+2/-1)',
  'Help: g?',
  'Untracked files (1)',
  '? new.txt',
  '',
  'Unstaged changes (1)',
  'M changed.txt',
  '',
  'Staged changes (1)',
  'M staged.txt',
  '',
}
vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
vim.bo.filetype = 'fugitivestatus'
assert(vim.b.current_syntax == 'fugitivestatus')
local function group(row, col)
  return vim.fn.synIDattr(vim.fn.synID(row, col, 1), 'name')
end
assert(group(2, 1) == 'fugitiveHeader', 'Upstream label lost its color: ' .. group(2, 1))
assert(group(2, 11) == 'fugitiveSymbolicRef', 'Upstream ref lost its color: ' .. group(2, 11))
assert(group(2, lines[2]:find('(+', 1, true)) == 'fugitiveAheadBehind')
assert(group(5, 1) == 'fugitiveUntrackedModifier', 'Untracked ? lost its color: ' .. group(5, 1))
assert(group(8, 1) == 'fugitiveUnstagedModifier', 'Unstaged M lost its color: ' .. group(8, 1))
assert(group(11, 1) == 'fugitiveStagedModifier', 'Staged M lost its color: ' .. group(11, 1))
assert(vim.fn.exists('*FugitiveGitDir') == 0 and vim.g.loaded_fugitive == nil)
print('PASS: standalone status syntax for upstream and file-state icons without Fugitive')
