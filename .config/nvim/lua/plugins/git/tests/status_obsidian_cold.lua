-- Exercise the shipped Lazy specs, real Obsidian client and a temporary vault.
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
local plugins = vim.fs.dirname(plugin)
local temporary = vim.fn.tempname()
local root, vault, unrelated = temporary .. '/captured', temporary .. '/vault', temporary .. '/unrelated'
vim.fn.mkdir(root, 'p'); vim.fn.mkdir(vault .. '/notes', 'p'); vim.fn.mkdir(unrelated, 'p')
vim.env.OBSIDIAN_VAULT = vault
vim.g.git_status_auto_fetch = false
local function git(args)
  local argv = { 'git', '-C', root, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid' }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait()
  assert(result.code == 0, result.stderr)
end
git({ 'init', '-qb', 'main' })
vim.fn.writefile({ 'one' }, root .. '/sample.txt')
git({ 'add', '.' }); git({ 'commit', '-qm', 'initial' })
vim.fn.writefile({ '---', 'project: captured', 'branch: main', '---', '# Captured project guide' }, vault .. '/notes/guide.md')
vim.fn.writefile({ '---', 'project: unrelated', 'branch: wrong', '---', '# Wrong project' }, vault .. '/notes/wrong.md')
assert(vim.system({ 'git', '-C', unrelated, 'init', '-qb', 'wrong' }):wait().code == 0)
local installed = vim.fn.stdpath('data') .. '/lazy'
vim.opt.rtp:prepend(installed .. '/lazy.nvim')
vim.opt.rtp:prepend(installed .. '/plenary.nvim')
local git_spec = dofile(plugin .. '/init.lua'); git_spec.dir = plugin
local obsidian_spec = dofile(plugins .. '/obsidian.lua')
local extension = dofile(plugins .. '/obsidian-extension/init.lua'); extension.dir = plugins .. '/obsidian-extension'
require('lazy').setup({ spec = { git_spec, obsidian_spec, extension, { 'Saghen/blink.compat', lazy = true } }, install = { missing = false },
  checker = { enabled = false }, change_detection = { enabled = false }, lockfile = temporary .. '/lock.json',
  performance = { rtp = { reset = false }, cache = { enabled = false } } })
assert(not package.loaded['git'] and not package.loaded['obsidian'])
vim.cmd('cd ' .. vim.fn.fnameescape(root))
vim.cmd('GitStatus')
local b = vim.api.nvim_get_current_buf()
local function text() return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), '\n') end
assert(vim.wait(10000, function() return text():find('Captured project guide', 1, true) end, 10), text())
assert(package.loaded['obsidian'] and package.loaded['obsidian_extension.features.related'])
assert(tostring(require('obsidian').get_client().dir) == vault, 'Shelf duplicated/ignored the configured workspace')
local at
for row, info in pairs(require('git.features.status_modules').rows(b)) do
  if info.item and info.item.path == vault .. '/notes/guide.md' then at = row end
end
assert(at, 'Shelf did not expose a real note item')
local line = vim.api.nvim_buf_get_lines(b, at - 1, at, false)[1]
local date = os.date('%Y-%m-%d', vim.uv.fs_stat(vault .. '/notes/guide.md').mtime.sec)
assert(line == 'Captured project guide  ' .. date, 'Note names should be flush left with a modification date')
local muted = false
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(b, vim.api.nvim_create_namespace('git_status_modules'),
  { at - 1, 0 }, { at - 1, -1 }, { details = true })) do
  if mark[4].hl_group == 'Comment' and mark[3] == #'Captured project guide' + 2 then muted = true end
end
assert(muted, 'Modification dates should use muted highlighting')
local captured = require('git.features.status_renderer').context(b)
assert(vim.bo[b].filetype == 'gitstatus' and vim.api.nvim_buf_get_name(b):match('^git%-status://'))
assert(captured.root == root and captured.branch == 'main', 'Context must come from the Status Git snapshot')
-- An unrelated cwd must not become the shelf's project/branch on a reload.
vim.cmd('cd ' .. vim.fn.fnameescape(unrelated))
vim.fn.writefile({ '---', 'project: captured', 'branch: main', '---', '# Verified captured context' }, vault .. '/notes/guide.md')
require('git.features.status_modules').refresh(b)
assert(vim.wait(5000, function() return text():find('Verified captured context', 1, true) end, 10), text())
assert(not text():find('Wrong project', 1, true), 'Shelf used the active cwd instead of its captured repository')
local info = require('git.features.status_modules').at(b, at)
assert(info and info.item.score == 200 and vim.tbl_contains(info.item.reasons, 'branch'),
  'Shelf lost project/branch matching in a Status buffer after changing cwd')
vim.api.nvim_win_set_cursor(0, { at, 0 })
vim.fn.maparg('<CR>', 'n', false, true).callback()
assert(vim.api.nvim_buf_get_name(0) == vault .. '/notes/guide.md')
vim.api.nvim_buf_delete(b, { force = true })
vim.fn.delete(temporary, 'rf')
print('PASS: shipped Lazy configuration cold-loads the Obsidian shelf and opens a real workspace note')
