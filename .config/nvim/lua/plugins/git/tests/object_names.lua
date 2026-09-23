local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
local objects = require('git.objects')
local root = vim.fn.tempname() .. ' name %23 # space'; vim.fn.mkdir(root .. '/nested/deep', 'p')
local function git(args) return vim.trim(objects.run(root, args)) end
git({ 'init', '-q' }); git({ 'config', 'user.name', 'Test' }); git({ 'config', 'user.email', 'test@example.invalid' }); git({ 'config', 'commit.gpgsign', 'false' })
local path = 'nested/deep/acp.lua'
local special = 'nested/deep/日本 %2f # ?.lua'
vim.fn.writefile({ 'normal' }, root .. '/' .. path)
vim.fn.writefile({ 'special' }, root .. '/' .. special)
git({ 'add', '.' }); git({ 'commit', '-qm', 'first' })
local hash = git({ 'rev-parse', 'HEAD' })
require('git').setup()
local expected = 'git-object://' .. root:gsub('%%', '%%25'):gsub('#', '%%23') .. '//' .. hash .. '/' .. path
assert(objects.uri(root, hash .. ':' .. path) == expected)
vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/' .. path))
vim.cmd('Gedit HEAD:%')
local buf = vim.api.nvim_get_current_buf()
assert(vim.api.nvim_buf_get_name(buf) == expected)
assert(vim.fn.expand('%:t') == 'acp.lua', 'Basename must be a filename, not the whole encoded URI')
local label = 'acp.lua [' .. hash:sub(1, 7) .. ']'
assert(require('git.display').name(buf) == label)
assert(dofile(vim.fs.dirname(plugin) .. '/bufferline.lua').opts.options.name_formatter({ bufnr = buf, name = 'acp.lua' }) == label)
vim.cmd('bdelete')
vim.cmd('edit ' .. vim.fn.fnameescape(expected))
assert(vim.api.nvim_get_current_line() == 'normal' and vim.b.git_object.path == path)
-- Existing all-escaped URIs must continue to resolve from saved quickfix/jumps.
local old = 'git-object://' .. vim.uri_encode(root, 'rfc2396') .. '//' .. vim.uri_encode(hash .. ':' .. path, 'rfc2396')
vim.cmd('edit ' .. vim.fn.fnameescape(old))
assert(vim.api.nvim_get_current_line() == 'normal' and require('git.display').name(vim.api.nvim_get_current_buf()) == label)
objects.open(hash .. ':' .. special, 'edit', root)
assert(vim.api.nvim_get_current_line() == 'special' and vim.b.git_object.path == special)
-- Statusline '%' must be literal: otherwise %f in an escaped URI recursively
-- expands the full filename, producing the repeated path reported in the UI.
local config
package.loaded.lualine = { setup = function(value) config = value end, refresh = function() end }
package.loaded.lazyagent = { status = function() return '' end }
dofile(vim.fs.dirname(plugin) .. '/lualine.lua').config()
local compact = require('git.display').name(vim.api.nvim_get_current_buf())
for _, render in ipairs({ config.sections.lualine_c[6][1], config.inactive_sections.lualine_a[1][1] }) do
  assert(vim.api.nvim_eval_statusline(render(), {}).str == compact)
end
local snapshot = vim.api.nvim_get_current_buf()
vim.cmd('new')
assert(dofile(vim.fs.dirname(plugin) .. '/incline.lua').opts.render({ buf = snapshot }) == compact)
vim.cmd('close')
local special_uri = vim.api.nvim_buf_get_name(0)
vim.cmd('bdelete'); vim.cmd('edit ' .. vim.fn.fnameescape(special_uri))
assert(vim.b.git_object.path == special, 'Percent sequences must be decoded exactly once')
objects.open(':0:' .. path, 'edit', root)
assert(vim.api.nvim_buf_get_name(0):match('//0/nested/deep/acp.lua$'))
assert(require('git.display').name(vim.api.nvim_get_current_buf()) == 'acp.lua [0]')
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'index' }); vim.cmd('write')
assert(git({ 'show', ':' .. path }) == 'index')
-- Different revisions/repositories keep distinct identity despite compact labels.
assert(objects.uri(root, hash .. ':' .. path) ~= objects.uri(root .. '-other', hash .. ':' .. path))
for _, b in ipairs(vim.api.nvim_list_bufs()) do pcall(vim.api.nvim_buf_delete, b, { force = true }) end
vim.fn.delete(root, 'rf')
print('PASS: Fugitive-style readable paths, compact labels, legacy URI reload, Unicode/percent/space paths, writable index')
