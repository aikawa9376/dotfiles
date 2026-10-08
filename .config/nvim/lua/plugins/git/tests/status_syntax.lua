local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
vim.opt.rtp:prepend(plugin)
vim.cmd('syntax enable')
local lines = {
  'Head: main',
  'Upstream: origin/main (+2/-1)',
  'Untracked files (1)',
  '? new.txt',
  '',
  'Unstaged changes (1)',
  'M changed.txt',
  '',
  'Staged changes (1)',
  'M staged.txt',
  '',
  'Tag: v1.0',
  'Tags: v1.0 (2), v2.0 (1)',
  'Remote: publish/main',
}
vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
vim.bo.filetype = 'gitstatus'
assert(vim.b.current_syntax == 'gitstatus')
local function group(row, col)
  return vim.fn.synIDattr(vim.fn.synID(row, col, 1), 'name')
end
assert(group(2, 1) == 'gitHeader', 'Upstream label lost its color: ' .. group(2, 1))
assert(group(2, 11) == 'gitSymbolicRef', 'Upstream ref lost its color: ' .. group(2, 11))
assert(group(2, lines[2]:find('(+', 1, true)) == 'gitAheadBehind')
assert(group(4, 1) == 'gitUntrackedModifier', 'Untracked ? lost its color: ' .. group(4, 1))
assert(group(7, 1) == 'gitUnstagedModifier', 'Unstaged M lost its color: ' .. group(7, 1))
assert(group(10, 1) == 'gitStagedModifier', 'Staged M lost its color: ' .. group(10, 1))
assert(group(12, 1) == 'gitHeader' and group(13, 1) == 'gitHeader',
  'tag headers were parsed as foldable commit sections')
assert(group(14, 1) == 'gitHeader' and group(14, 9) == 'gitSymbolicRef',
  'Remote header lost its ref highlighting')
print('PASS: standalone status syntax for upstream and file-state icons without Git')
