local M = {}

-- A separate spec keeps editor integrations and their startup side effects out
-- of the Git application, including session autosave and automatic cwd changes.
function M.plugins()
  local specs = {}
  for _, name in ipairs({
    'nightfox', 'notify', 'noice', 'fzf-lua', 'git', 'flog', 'diffview',
    'gitsigns', 'treesitter', 'inkstone', 'oil',
  }) do specs[#specs + 1] = { import = 'plugins.' .. name } end
  vim.list_extend(specs, {
    { 'git', opts = function() return { status_modules = {} } end },
    { 'aikawa9376/utilities.lua', lazy = true },
    { 'nvim-lua/plenary.nvim', lazy = true },
    { 'MunifTanjim/nui.nvim', lazy = true },
    { 'kyazdani42/nvim-web-devicons', lazy = true },
  })
  return specs
end

function M.start()
  local ok, err = pcall(function()
    assert(vim.fn.argc() <= 1, 'Git accepts one repository directory')
    local directory = vim.fn.argc() == 1 and vim.fn.argv(0) or vim.fn.getcwd()
    assert(vim.fn.isdirectory(directory) == 1, 'Git expects a repository directory; use nvim to edit files')
    local result = vim.system({ 'git', '-C', directory, 'rev-parse', '--show-toplevel' }, { text = true }):wait()
    assert(result.code == 0, 'Not in a Git working tree: ' .. directory)
    local root = vim.trim(result.stdout)
    vim.api.nvim_set_current_dir(root)
    require('lazy').load({ plugins = { 'git' } })
    require('git.features.application').start(root)
  end)
  if not ok then
    vim.api.nvim_err_writeln(tostring(err))
    vim.cmd('cquit 1')
  end
end

function M.setup()
  vim.g.mapleader = ' '
  require('config.open')
  require('config.option')
  -- The editor's command.lua normally initializes detection before option.lua
  -- sets this legacy guard to 0 (which is truthy in Lua). This profile skips it.
  vim.g.did_load_filetypes = nil
  vim.cmd('filetype plugin indent on')
  require('config.colorScheme')
  require('config.ui_select')
  require('config.lazy')
  vim.cmd('syntax enable')
  vim.o.showtabline = 0
  vim.o.laststatus = 3
  vim.o.cmdheight = 1
  vim.o.number = false
  vim.o.relativenumber = false
  vim.o.statuscolumn = ''
  vim.o.list = false
  vim.keymap.set({ 'n', 'x' }, ';', '<Leader>', { remap = true })
  if vim.v.vim_did_enter == 1 then M.start()
  else
    vim.api.nvim_create_autocmd('VimEnter', {
      group = vim.api.nvim_create_augroup('GitApplicationStartup', { clear = true }),
      once = true, callback = M.start,
    })
  end
end

return M
