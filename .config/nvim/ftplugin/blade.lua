-- Only apply these settings once per buffer
if vim.b.did_ftplugin_blade then
  return
end
vim.b.did_ftplugin_blade = true

-- Buffer-local options
-- vim.opt_local.expandtab = true
-- vim.opt_local.shiftwidth = 2
-- vim.opt_local.tabstop = 2
-- vim.opt_local.softtabstop = 2

-- Buffer-local mappings (use <buffer> to ensure mappings only apply to blade files)
vim.keymap.set('n', 'gd', function()
  require('laravel.navigate').goto_laravel_string()
end, { buffer = true, noremap = true })

-- コメント: ファイルタイププラグインを読み込んだことを示す
-- vim.api.nvim_echo({{"Blade filetype plugin loaded", "MoreMsg"}}, false, {})

-- ファイルタイプに関する追加情報を設定
-- vim.b.undo_ftplugin = "setlocal expandtab< shiftwidth< tabstop< softtabstop<"
