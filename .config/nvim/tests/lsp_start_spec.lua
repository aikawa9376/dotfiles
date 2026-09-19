-- Run from the dotfiles root with nvim --headless --clean -u NONE -l <this file>.
local calls = 0
local clients = {}
package.preload.mason = function() return {setup=function() end} end
vim.fn.stdpath = function() return '/tmp' end
vim.fs.dir = function() return function() end end
vim.lsp.enable = function() end
vim.lsp.get_clients = function() return clients end
vim.lsp.start = function() calls = calls + 1; return 42 end
local b = vim.api.nvim_get_current_buf()
dofile('.config/nvim/lua/lsp/init.lua')
assert(vim.lsp.start({name='lua_ls'}, {bufnr=b}) == 42)
clients = {{id=7, is_stopped=function() return false end}}
assert(vim.lsp.start({name='lua_ls'}, {bufnr=b}) == 7 and calls == 1)
clients = {{id=7, is_stopped=function() return true end}}
assert(vim.lsp.start({name='lua_ls'}, {bufnr=b}) == 42 and calls == 2)
clients = {}
print('LSP start: active client reuse, stopped client replacement, return IDs passed')
