local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
vim.opt.rtp:prepend(vim.fn.stdpath('data') .. '/lazy/lazy.nvim')
local spec = dofile(plugin .. '/init.lua'); spec.dir = plugin
require('lazy').setup({ spec = { spec }, install = { missing = false }, checker = { enabled = false },
  change_detection = { enabled = false }, lockfile = vim.fn.tempname(),
  performance = { rtp = { reset = false }, cache = { enabled = false } } })
assert(not package.loaded['git'], 'Git loaded before a trigger')
assert(vim.fn.exists(':GitStatusTree') == 2, 'tree command was unavailable before loading')
assert(vim.fn.exists(':G') == 2 and vim.fn.exists(':Gclog') == 2)
assert(vim.fn.exists(':GitApply') == 2 and vim.fn.exists(':GitReverse') == 2,
  'patch commands were unavailable before the plugin loaded')
assert(vim.fn.exists(':GitUndo') == 2 and vim.fn.exists(':GitRedo') == 2,
  'history commands were unavailable before the plugin loaded')
assert(vim.fn.exists(':GitRebasePlan') == 2 and vim.fn.exists(':GitRebaseBase') == 2,
  'rebase planning commands were unavailable before the plugin loaded')
require('lazy').load({ plugins = { 'git' } })
assert(package.loaded['git'])
for _, name in ipairs(spec.cmd) do assert(vim.fn.exists(':' .. name) == 2, 'Missing command: ' .. name) end
local active = table.concat(vim.fn.readfile(vim.fs.dirname(vim.fs.dirname(plugin)) .. '/config/lazy.lua'), '\n')
assert(active:find('import = "plugins.git"', 1, true))
assert(not active:find('import = "plugins.diff-dim"', 1, true))
assert(active:find('import = "plugins.flog"', 1, true))
print('PASS: Lazy triggers, registered Git commands and optional Flog configuration')
