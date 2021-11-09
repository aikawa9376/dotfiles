local cmd = vim.cmd

cmd([[
  augroup MyAutoCmd
    autocmd!
  augroup END
]])

cmd('filetype plugin indent on')
cmd('autocmd MyAutoCmd InsertLeave * set nopaste')

cmd([[
augroup MyAutoCmd
  autocmd FileType help,qf nnoremap <buffer> <CR> <CR>
  autocmd FileType help,qf,fugitive nnoremap <buffer><nowait> q <C-w>c
  autocmd FileType help,qf,fugitive,defx,vista nnoremap <buffer><nowait> <C-c> <C-w>c
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
cmd([[
if exists(':terminal')
  autocmd TermOpen * nnoremap <buffer> <silent><ESC> :close<CR>
endif
]])

cmd([[
augroup mylightline
  autocmd! FileType fzf
  autocmd  FileType fzf set laststatus=0 noshowmode noruler noshowcmd
  autocmd  BufLeave * set laststatus=2 showmode ruler showcmd
augroup END
]])
