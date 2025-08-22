-- Only apply these settings once per buffer
if vim.b.did_ftplugin_php then
  return
end
vim.b.did_ftplugin_php = true

-- Buffer-local options
-- vim.opt_local.expandtab = true
-- vim.opt_local.shiftwidth = 2
-- vim.opt_local.tabstop = 2
-- vim.opt_local.softtabstop = 2

-- Buffer-local mappings (use <buffer> to ensure mappings only apply to php files)
vim.api.nvim_create_user_command("Xdebug", function()
  local lnum = vim.fn.line(".")
  vim.fn.append(lnum, "xdebug_break();")
  vim.cmd('normal! j==')
  vim.cmd('DapContinue')
end, { nargs = 0 })

-- コメント: ファイルタイププラグインを読み込んだことを示す
-- vim.api.nvim_echo({{"Php filetype plugin loaded", "MoreMsg"}}, false, {})

-- ファイルタイプに関する追加情報を設定
-- vim.b.undo_ftplugin = "setlocal expandtab< shiftwidth< tabstop< softtabstop<"
