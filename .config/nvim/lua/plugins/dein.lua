-- neovimのリモートプラグインを遅延読み込み
vim.api.nvim_set_var('dein#lazy_rplugins', 1)
vim.api.nvim_set_var('dein#install_max_processes', 16)
vim.api.nvim_set_var('dein#enable_notification', 1)

local dein_dir = vim.env.HOME .. '/.cache/dein'
local dein_repo_dir = dein_dir .. '/repos/github.com/Shougo/dein.vim'

if not string.match(vim.o.runtimepath, '/dein.vim') then
  if vim.fn.isdirectory(dein_repo_dir) ~= 1 then
    os.execute('git clone https://github.com/Shougo/dein.vim '..dein_repo_dir)
  end
  vim.o.runtimepath = dein_repo_dir .. ',' .. vim.o.runtimepath
end

if vim.call('dein#load_state', dein_dir) == 1 then
  local dein_toml_dir = vim.env.HOME .. '/.config/nvim'
  local dein_toml = dein_toml_dir .. '/dein.toml'
  local dein_toml_lazy = dein_toml_dir .. '/dein_lazy.toml'

  vim.call('dein#begin', dein_dir)
  vim.call('dein#load_toml', dein_toml, {lazy = 0})
  vim.call('dein#load_toml', dein_toml_lazy, {lazy = 1})

  vim.call('dein#end')
  vim.call('dein#save_state')
end

-- 不足プラグインの自動インストール
if vim.fn.has('vim_starting') == 1 and vim.call('dein#check_install') == 1 then
  vim.call('dein#install')
end
-- 高速アップデート用設定
vim.cmd('source $XDG_CONFIG_HOME/nvim/dein_key.vim')
