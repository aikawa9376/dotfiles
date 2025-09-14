vim.cmd([[
  augroup MyAutoCmd
    autocmd!
  augroup END
]])

vim.cmd("filetype plugin indent on")
vim.cmd("autocmd MyAutoCmd InsertLeave * set nopaste")

vim.cmd([[
augroup MyAutoCmd
  autocmd FileType help,qf nnoremap <buffer> <CR> <CR>
  autocmd FileType help,qf,fugitive nnoremap <buffer><nowait> q <C-w>c
  autocmd FileType fugitiveblame let @q="gq"
  autocmd FileType fugitiveblame nmap <buffer><nowait> q @q
  autocmd FileType fugitiveblame nmap <buffer><nowait> <BS> <C-w><C-w><M-o><Leader>gb
  autocmd FileType noice nnoremap <buffer><nowait> <ESC> <C-w>c
  autocmd FileType help,qf,fugitive,defx,vista,neo-tree, nnoremap <buffer><nowait> <C-c> <C-w>c
  autocmd FileType far nnoremap <buffer><nowait> <C-c> :bdelete<cr>
  autocmd FileType agit nnoremap <buffer><nowait> <C-c> <C-w>o:tabc<CR>
  autocmd FileType Mundo nnoremap <buffer><nowait> <C-c> :bdelete<CR>:bdelete<CR>
  autocmd FileType gitcommit nmap <buffer><nowait> q :<c-u>wq<CR>
  autocmd FileType gitcommit nmap <buffer><nowait> <C-c> :<c-u>wq<CR>
  autocmd FileType fugitive nnoremap <buffer><Space>gp :<c-u>Git! push<CR><C-w>c
  autocmd FileType dbui,dbout,sql nnoremap <buffer><nowait> <C-c> :DBUIDelete<CR>
  autocmd FileType dbui,dbout,sql nnoremap <buffer><nowait> q :DBUIDelete<CR>
  autocmd FileType DiffviewFiles,DiffviewFileHistory nnoremap <buffer><nowait> q :DiffviewClose<CR>
  autocmd FileType DiffviewFiles,DiffviewFileHistory nnoremap <buffer><nowait> <C-c> :DiffviewClose<CR>
  autocmd FileType spectre_panel nnoremap <buffer><nowait> q <C-w>c
  autocmd FileType spectre_panel nnoremap <buffer><nowait> <C-c> <C-w>c
augroup END
]])

-- terminal mode
vim.cmd([[
if exists(':terminal')
  autocmd TermOpen * nnoremap <buffer> <silent><ESC> :close<CR>
endif
]])

vim.cmd([[
augroup mylightline
  autocmd! FileType fzf
  autocmd  FileType fzf set laststatus=0 noshowmode noruler noshowcmd
  autocmd  BufLeave * set laststatus=3 showmode ruler showcmd
augroup END
]])

vim.api.nvim_create_user_command("TermForceCloseAll", function()
  local term_bufs = vim.tbl_filter(function(buf)
    return vim.api.nvim_get_option_value("buftype", { buf = buf }) == "terminal"
  end, vim.api.nvim_list_bufs())

  for _, t in ipairs(term_bufs) do
    vim.cmd("bd! " .. t)
  end
end, {})
