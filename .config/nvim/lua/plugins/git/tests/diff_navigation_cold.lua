-- Native diff and plain patch entry points load navigation before any Git UI.
local source = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
local plugin = vim.fs.dirname(vim.fs.dirname(source))
if not vim.env.GIT_DIFF_COLD_MODE then
  for _, mode in ipairs({ 'native', 'unified' }) do
    local result = vim.system({ vim.v.progpath, '--headless', '--clean', '-u', 'NONE', '-i', 'NONE', '-l', source },
      { env = { GIT_DIFF_COLD_MODE = mode }, text = true }):wait()
    assert(result.code == 0, mode .. ': ' .. (result.stdout or '') .. (result.stderr or ''))
  end
  print('PASS: cold native diff and unified patch load navigation without Gitsigns')
  return
end
vim.opt.rtp:prepend(vim.fn.stdpath('data') .. '/lazy/lazy.nvim')
local spec = dofile(plugin .. '/init.lua'); spec.dir = plugin
require('lazy').setup({ spec = { spec }, install = { missing = false }, checker = { enabled = false },
  change_detection = { enabled = false }, lockfile = vim.fn.tempname(),
  performance = { rtp = { reset = false }, cache = { enabled = false } } })
assert(not package.loaded['git'], 'Git loaded before opening a diff')
local api = vim.api
if vim.env.GIT_DIFF_COLD_MODE == 'native' then
  dofile(vim.fs.dirname(vim.fs.dirname(plugin)) .. '/config/command.lua')
  local left = api.nvim_get_current_win()
  api.nvim_buf_set_name(0, 'diff-cold-left')
  api.nvim_buf_set_lines(0, 0, -1, false, { 'a', 'same', 'c' })
  vim.cmd('vnew'); api.nvim_buf_set_name(0, 'diff-cold-right')
  api.nvim_buf_set_lines(0, 0, -1, false, { 'b', 'same', 'd' })
  vim.cmd('diffthis'); api.nvim_set_current_win(left); vim.cmd('diffthis'); vim.cmd('diffupdate')
  -- OptionSet is suppressed during startup in headless -l executions.
  api.nvim_exec_autocmds('OptionSet', { pattern = 'diff', modeline = false })
else
  api.nvim_buf_set_lines(0, 0, -1, false, { '@@ -1 +1 @@', '-a', '+b', '@@ -3 +3 @@', '-c', '+d' })
  vim.bo.filetype = 'diff'
end
assert(vim.wait(3000, function()
  return package.loaded['git'] and vim.fn.maparg(']]', 'n', false, true).desc == 'Next diff hunk (wrap)'
end, 5), 'Cold diff did not load hunk navigation')
api.nvim_win_set_cursor(0, { 1, 0 })
vim.cmd('normal ]]')
assert(api.nvim_win_get_cursor(0)[1] == (vim.env.GIT_DIFF_COLD_MODE == 'native' and 3 or 4))
vim.cmd('normal ]]'); assert(api.nvim_win_get_cursor(0)[1] == 1)
vim.cmd('normal [[')
assert(api.nvim_win_get_cursor(0)[1] == (vim.env.GIT_DIFF_COLD_MODE == 'native' and 3 or 4))
assert(not package.loaded['gitsigns'], 'Hunk navigation unnecessarily loaded Gitsigns')
