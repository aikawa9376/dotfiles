" dein自体の自動インストール
let s:cache_home = empty($XDG_CACHE_HOME) ? expand('~/.cache') : $XDG_CACHE_HOME
let s:dein_dir = s:cache_home . '/dein'
let s:dein_repo_dir = s:dein_dir . '/repos/github.com/Shougo/dein.vim'
if !isdirectory(s:dein_repo_dir)
  call system('git clone https://github.com/Shougo/dein.vim ' . shellescape(s:dein_repo_dir))
endif
let &runtimepath = s:dein_repo_dir .','. &runtimepath
" プラグイン読み込み＆キャッシュ作成
let s:toml_file = fnamemodify(expand('<sfile>'), ':h').'/dein.toml'
let s:toml_lazy_file = fnamemodify(expand('<sfile>'), ':h').'/dein_lazy.toml'
if dein#load_state(s:dein_dir)
  call dein#begin(s:dein_dir)
  call dein#load_toml(s:toml_file, {'lazy': 0})
  call dein#load_toml(s:toml_lazy_file, {'lazy': 1})
  call dein#end()
  call dein#save_state()
endif
" 不足プラグインの自動インストール
if has('vim_starting') && dein#check_install()
  call dein#install()
endif
" 高速アップデート用設定
source $XDG_CONFIG_HOME/nvim/dein_key.vim

noremap  <Plug>(my-switch) <Nop>
nmap     <Leader>t <Plug>(my-switch)
nnoremap <silent> <Plug>(my-switch)s :<C-u>setl spell! spell?<CR>
nnoremap <silent> <Plug>(my-switch)l :<C-u>setl list! list?<CR>
nnoremap <silent> <Plug>(my-switch)t :<C-u>setl expandtab! expandtab?<CR>
nnoremap <silent> <Plug>(my-switch)w :<C-u>setl wrap! wrap?<CR>
nnoremap <silent> <Plug>(my-switch)p :<C-u>setl paste! paste?<CR>
nnoremap <silent> <Plug>(my-switch)b :<C-u>setl scrollbind! scrollbind?<CR>
nnoremap <silent> <Plug>(my-switch)i :<C-u>let g:indent_blankline_enabled = v:true<CR>:IndentBlanklineToggle<CR>

" ペーストモードを自動解除
autocmd MyAutoCmd InsertLeave * set nopaste

" neomutt用の設定はここ
augroup NeomuttSetting
  autocmd!
  autocmd BufRead,BufNewFile,BufEnter *mutt-* call s:neomutt_my_settings()
  autocmd BufRead *mutt-* call s:neomutt_feedkey()
augroup END
function! s:neomutt_my_settings() abort
  nnoremap <buffer><nowait> <C-Space> :wq<CR>
  nnoremap <buffer><nowait> q :xa<CR>
  setlocal statusline=%#Normal#
  Goyo
endfunction
function! s:neomutt_feedkey() abort
  call feedkeys('j}o')
endfunction
