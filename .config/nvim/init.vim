if !&compatible
  set nocompatible
endif

" reset augroup
augroup MyAutoCmd
  autocmd!
augroup END

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

" Required:
filetype on
filetype plugin indent on
syntax enable
set t_Co=256
set number
set backspace=indent,eol,start
set encoding=utf-8
set fileformats=unix,dos,mac
set fileencodings=utf-8,sjis
set ttimeoutlen=1
set completeopt=menuone
set noshowmode
set cursorline
set list
set undofile
set undodir=$HOME/.config/nvim/undo/
set listchars=tab:»-,extends:»,precedes:«,nbsp:%
set splitright
set splitbelow
set updatetime=100
set nofoldenable
set nospell
set spelllang=en,cjk

let g:loaded_gzip              = 1
let g:loaded_tar               = 1
let g:loaded_tarPlugin         = 1
let g:loaded_zip               = 1
let g:loaded_zipPlugin         = 1
let g:loaded_rrhelper          = 1
let g:loaded_2html_plugin      = 1
let g:loaded_vimball           = 1
let g:loaded_vimballPlugin     = 1
let g:loaded_getscript         = 1
let g:loaded_getscriptPlugin   = 1
let g:loaded_netrw             = 1
let g:loaded_netrwPlugin       = 1
let g:loaded_netrwSettings     = 1
let g:loaded_netrwFileHandlers = 1

nmap <Space> <Leader>
" nnoremap <nowait><Space> <Nop>
" nnoremap <nowait><BS>    <Nop>
" if !exists('g:mapleader')
"   let g:mapleader = "\<Space>"
" endif
" if !exists('g:maplocalleader')
"   let g:maplocalleader = "\<BS>"
" endif

noremap  <Plug>(my-switch) <Nop>
nmap     <Leader>t <Plug>(my-switch)
nnoremap <silent> <Plug>(my-switch)s :<C-u>setl spell! spell?<CR>
nnoremap <silent> <Plug>(my-switch)l :<C-u>setl list! list?<CR>
nnoremap <silent> <Plug>(my-switch)t :<C-u>setl expandtab! expandtab?<CR>
nnoremap <silent> <Plug>(my-switch)w :<C-u>setl wrap! wrap?<CR>
nnoremap <silent> <Plug>(my-switch)p :<C-u>setl paste! paste?<CR>
nnoremap <silent> <Plug>(my-switch)b :<C-u>setl scrollbind! scrollbind?<CR>
nnoremap <silent> <Plug>(my-switch)y :call <SID>toggle_syntax()<CR>
nnoremap <silent> <Plug>(my-switch)n :call <SID>toggle_relativenumber()<CR>
function! s:toggle_syntax() abort
  if exists('g:syntax_on')
    syntax off
    redraw
    echo 'syntax off'
  else
    syntax on
    redraw
    echo 'syntax on'
  endif
endfunction
function! s:toggle_relativenumber() abort
  if &relativenumber == 1
     setlocal norelativenumber
  else
     setlocal relativenumber
  endif
endfunction

" Insertモードのときカーソルの形状を変更
if has('unix')
  if &term =~ 'screen'
    let &t_ti.= "\eP\e[1 q\e\\"
    let &t_SI.= "\eP\e[5 q\e\\"
    let &t_EI.= "\eP\e[1 q\e\\"
    let &t_te.= "\eP\e[0 q\e\\"
  elseif &term =~ 'xterm'
    let &t_ti.="\e[1 q"
    let &t_SI.="\e[5 q"
    let &t_EI.="\e[1 q"
    let &t_te.="\e[0 q"
  elseif  has('mac')
    let &t_SI = "\<Esc>Ptmux;\<Esc>\<Esc>]50;CursorShape=1\x7\<Esc>\\"
    let &t_EI = "\<Esc>Ptmux;\<Esc>\<Esc>]50;CursorShape=0\x7\<Esc>\\"
  endif
endif

" auto fcitx
let g:input_toggle = 1
function! Fcitx2en()
  let s:input_status = system("fcitx-remote")
  if s:input_status == 2
    let g:input_toggle = 1
    let l:a = system("fcitx-remote -c")
  endif
endfunction
"Leave Insert mode
autocmd InsertLeave * call Fcitx2en()

" ファイル処理関連の設定
set confirm    " 保存されていないファイルがあるときは終了前に保存確認
set hidden     " 保存されていないファイルがあるときでも別のファイルを開くことが出来る
set autoread   " 外部でファイルに変更がされた場合は読みなおす
set nobackup   " ファイル保存時にバックアップファイルを作らない
set noswapfile " ファイル編集中にスワップファイルを作らない
set switchbuf=useopen " 新しく開く代わりにすでに開いてあるバッファを開く
nmap <Leader>z :BufOnly<CR>

" 検索をファイルの先頭へ循環しない
" set nowrapscan

" 大文字小文字の区別なし
set ignorecase
set smartcase

" 検索語句をハイライト ESC二回でオフ
set incsearch
set inccommand=split
set hlsearch
nmap <silent> <Esc><Esc> :<C-u>call HlTextToggle()<CR>
nmap <Plug>(my-hltoggle) mz<Esc>:%s/\(<C-r>=expand("<cword>")<Cr>\)//gn<CR>`z
function! HlTextToggle()
  if v:hlsearch != 0
    call feedkeys(":noh\<CR>")
  else
    call feedkeys("\<Plug>(my-hltoggle)")
  endif
endfunction

" スクロール時に表示を10行確保
set scrolloff=10

" x キー削除でデフォルトレジスタに入れない
nnoremap x "_x
vnoremap x "_x
nnoremap cl "_s
vnoremap cl "_s
nnoremap <silent> dd :<C-u>call <SID>remove_line_brank(v:count1)<CR>
function! s:remove_line_brank(count)
  for i in range(1, v:count1)
    if getline('.') == ''
      .delete _
    else
      .delete
    endif
  endfor
  call repeat#set('dd', v:count1)
endfunction

nnoremap <silent> dD :<C-u>call <SID>remove_line_brank_all(v:count1)<CR>
function! s:remove_line_brank_all(count)
  for i in range(1, v:count1)
    if getline('.') == ''
      .delete _
    else
      .delete
    endif
  endfor
  while getline('.') == ''
      .delete _
  endwhile
  call repeat#set('dD', v:count1)
endfunction

nmap <silent>]p :<c-u>call YankLine('j')<CR>
nmap <silent>[p :<c-u>call YankLine('k')<CR>
nmap <silent><expr> gV '`['.strpart(getregtype(), 0, 1).'`]'
function! s:YanksAfterIndent()
  normal! gV=gV^
endfunction
function! YankLine(flag)
  if a:flag == 'j'
    let line = line('.')
    let repeat = ']p'
  else
    let line = line('.') - 1
    let repeat = '[p'
  endif
  call append(line, '')
  execute 'normal! ' . a:flag . 'p'
  call s:YanksAfterIndent()
  call repeat#set(repeat, '')
endfunction

" ヤンクした後に末尾に移動
nmap <silent><C-t> :<C-u>call YankTextToggle()<CR>
function! YankTextToggle()
  if b:yank_toggle_flag != 0
    execute 'normal `['
    let b:yank_toggle_flag = 0
  else
    execute 'normal `]'
    let b:yank_toggle_flag = 1
  endif
endfunction
function! s:yank_toggle_flag() abort
  let b:yank_toggle_flag = 1
endfunction
augroup YankStart
  autocmd!
  autocmd TextYankPost,TextChanged,InsertEnter * call s:yank_toggle_flag()
augroup END

" 選択範囲のインデントを連続して変更
vnoremap < <gv
vnoremap > >gv
set smartindent
nnoremap <Leader>i mzgg=G`z

" ノーマルモード中にEnterで改行
nnoremap <CR> i<CR><Esc>
nnoremap <Leader><CR> $a<CR><Esc>
nnoremap <Leader>s i<Space><ESC>
nnoremap <M-d> mzo<ESC>`zj
nnoremap <M-u> mzO<ESC>`zk
nnoremap X diw

" インサートモード移行時に自動インデント
function! IndentWithI()
    if len(getline('.')) == 0
        return "cc"
    else
        return "i"
    endif
endfunction
nnoremap <expr> i IndentWithI()
" インサートモードで bash 風キーマップ
inoremap <C-a> <C-g>U<C-o>^
inoremap <C-e> <C-g>U<C-o>$<C-g>U<Right>
inoremap <C-b> <C-g>U<Left>
inoremap <C-f> <C-g>U<Right>
inoremap <C-n> <C-g>U<Down>
inoremap <C-p> <C-g>U<Up>
inoremap <C-h> <C-g>U<BS>
inoremap <C-d> <C-g>U<Del>
inoremap <C-k> <C-g>U<C-o>D<Right>
inoremap <C-u> <C-g>U<C-o>d^
inoremap <C-w> <C-g>U<C-o>db
inoremap <C-o> <C-g>U<C-o>o
inoremap <M-f> <C-g>U<C-o>w
inoremap <M-b> <C-g>U<C-o>b
inoremap <M-P> <C-g>U<C-o>P
" TODO undoきれなくする 関数？
inoremap <C-v> <C-g>U<C-o>yh<C-g>U<C-r>"<C-g>U<Right>

" 文字選択・移動など
nnoremap Y y$
nnoremap V v$
nnoremap vv V
" mrは operator replace用
nnoremap y mvmry
nnoremap v mvv
nnoremap d mvd
nnoremap c mvc
nnoremap <M-x> vy
nnoremap <Leader>U `v
nnoremap <C-h> ^
vnoremap <C-h> ^
nnoremap <C-l> $l
vnoremap <C-l> $l
nnoremap <silent><M-m> :call cursor(0,strlen(getline("."))/2)<CR>
" すごく移動する
nnoremap <C-j> 3gj
vnoremap <C-j> 3gj
nnoremap <C-k> 3gk
vnoremap <C-k> 3gk

" gJで空白を削除する
fun! JoinSpaceless()
    execute 'normal gj'
    " Character under cursor is whitespace?
    if matchstr(getline('.'), '\%' . col('.') . 'c.') =~ '\s'
        " When remove it!
        execute 'normal dw'
    endif
    call repeat#set('gJ', v:count1)
endfun
nnoremap gj J
nnoremap gJ :call JoinSpaceless()<CR>

" コマンドモードでemacs
cnoremap <C-b> <Left>
cnoremap <C-f> <Right>
cnoremap <C-n> <Down>
cnoremap <C-p> <Up>
cnoremap <C-a> <Home>
cnoremap <C-e> <End>
cnoremap <C-d> <Del>

" terminal mode
command! -nargs=* TERM split | resize20 | term <args>
nmap <silent><F12> :<c-u>TERM<CR>
tnoremap <silent><C-[> <C-\><C-n>

" 行末の1文字先までカーソルを移動できるように
set virtualedit=onemore

" 動作環境との統合
" OSのクリップボードをレジスタ指定無しで Yank, Put 出来るようにする
set clipboard=unnamed,unnamedplus

" マウスの入力を受け付ける
set mouse=a

" tab/indentの設定
set shellslash
set expandtab "タブ入力を複数の空白入力に置き換える
set tabstop=2 "画面上でタブ文字が占める幅
set shiftwidth=2 "自動インデントでずれる幅
set softtabstop=2
" 連続した空白に対してタブキーやバックスペースキーでカーソルが動く幅
set autoindent "改行時に前の行のインデントを継続する
set smartindent "改行時に入力された行の末尾に合わせて次の行のインデントを増減する
" set wildmenu wildmode=list,full "コマンドモード補完
set wildoptions+=pum
" set pumblend=99

" 入力モード中に素早くJJと入力した場合はESCとみなす
inoremap <silent> jj <Esc>
inoremap <silent> っｊ <Esc>
nnoremap <silent> <expr> っｊ Fcitx2en()

" ペーストモードを自動解除
autocmd MyAutoCmd InsertLeave * set nopaste

" ジャンプリストで中央に持ってくる
nnoremap <c-o> <c-o>zz
nnoremap <c-i> <c-o>zz
nnoremap g; g;zz
nnoremap g, g,zz
nnoremap <C-u> <C-u>zz
nnoremap <C-d> <C-d>zz
nnoremap <C-f> <C-f>zz
nnoremap <C-b> <C-b>zz
" 検索後にジャンプした際に検索単語を画面中央に持ってくる
nnoremap n nzz
nnoremap N Nzz

" ファイル操作系
nmap <Leader> <Nop>
nmap <Leader>w :<c-u>w<CR>
nmap <Leader>x :<c-u>Bdelete<CR>
nmap ZZ :<c-u>xa<CR>
nmap <silent> <M-b> :bnext<CR>
nmap <silent> <C-g> mz<C-^>`zzz
" QuickFixおよびHelpでは q でバッファを閉じる
autocmd MyAutoCmd FileType help,qf nnoremap <buffer> <CR> <CR>
autocmd MyAutoCmd FileType help,qf,fugitive nnoremap <buffer><nowait> q <C-w>c
autocmd MyAutoCmd FileType far_vim nnoremap <buffer><nowait> q <C-w>o:tabc<CR>
autocmd MyAutoCmd FileType gitcommit nmap <buffer><nowait> q :<c-u>wq<CR>
autocmd MyAutoCmd FileType fugitive nnoremap <buffer><Space>gp :<c-u>Gina push<CR><C-w>c

" qf enhanced
augroup qf_enhanced
  autocmd!
  autocmd FileType qf call s:qf_enhanced()
  function! s:qf_enhanced()
    nnoremap <buffer> p  <CR>zz<C-w>p
    nnoremap <silent> <buffer> dd :call <SID>del_entry()<CR>
    nnoremap <silent> <buffer> x :call <SID>del_entry()<CR>
    vnoremap <silent> <buffer> d :call <SID>del_entry()<CR>
    vnoremap <silent> <buffer> x :call <SID>del_entry()<CR>
    nnoremap <silent> <buffer> u :<C-u>call <SID>undo_entry()<CR>
  endfunction

  function! s:undo_entry()
    let history = get(w:, 'qf_history', [])
    if !empty(history)
      call setqflist(remove(history, -1), 'r')
    endif
  endfunction

  function! s:del_entry() range
    let qf = getqflist()
    let history = get(w:, 'qf_history', [])
    call add(history, copy(qf))
    let w:qf_history = history
    unlet! qf[a:firstline - 1 : a:lastline - 1]
    call setqflist(qf, 'r')
    execute a:firstline
  endfunction
augroup END

augroup vimrc-auto-mkdir
  autocmd!
  autocmd BufWritePre * call s:auto_mkdir(expand('<afile>:p:h'), v:cmdbang)
  function! s:auto_mkdir(dir, force)
    if !isdirectory(a:dir) && (a:force ||
    \    input(printf('"%s" does not exist. Create? [y/N]', a:dir)) =~? '^y\%[es]$')
      call mkdir(iconv(a:dir, &encoding, &termencoding), 'p')
    endif
  endfunction
augroup END

" window操作系
nmap <silent> \| :<c-u>vsplit<CR><C-w>h
nmap <silent> - :<c-u>split<CR><C-w>k

" 前回のカーソル位置からスタート
augroup vimrcEx
  au BufRead * if line("'\"") > 0 && line("'\"") <= line("$") |
    \ exe "normal g`\"" | endif
augroup END

" 文末に○○を付ける
nnoremap <M-;> mz$a;<ESC>`z
nnoremap <M-,> mz$a,<ESC>`z

" 補完系
inoremap <C-l> <C-x><C-l>
inoremap <M-n> <C-x><C-n>
inoremap <M-p> <C-x><C-p>

" vimrcをスペースドットで更新
if has('vim_starting')
  function s:reload_vimrc() abort
    execute printf('source %s', $MYVIMRC)
    if has('gui_running')
      execute printf('source %s', $MYGVIMRC)
    endif
    redraw
    echo printf('.vimrc/.gvimrc has reloaded (%s).', strftime('%c'))
  endfunction
endif
nmap <silent> <Plug>(my-reload-vimrc) :<C-u>call <SID>reload_vimrc()<CR>
nmap <Leader>, <Plug>(my-reload-vimrc)

" 固有のvimrcを用意 .vimrc.local
augroup vimrc-local
  autocmd!
  autocmd BufNewFile,BufReadPost * call s:vimrc_local(expand('<afile>:p:h'))
augroup END

function! s:vimrc_local(loc)
  let files = findfile('.vimrc.local', escape(a:loc, ' ') . ';', -1)
  for i in reverse(filter(files, 'filereadable(v:val)'))
    source `=i`
  endfor
endfunction

" php用の設定はここ
" TODO ftplutin setting
autocmd MyAutoCmd FileType php,phml call s:php_my_settings()
function! s:php_my_settings() abort
  nnoremap <buffer> <expr><F1> IsPhpOrHtml() ? ":set ft=html<CR>" : ":set ft=php<CR>"
  nnoremap <buffer> <M-4> bi$<ESC>e
  nnoremap <silent> <buffer> <F11> :PhpRefactorringMenu()<CR>
endfunction

function! IsPhpOrHtml() abort
  let fe = &filetype
  if fe == 'php'
    return 1
  elseif fe == 'phtml'
    return 1
  elseif fe == 'html'
    return 0
  endif
endfunction

" SQL用の設定はここ
autocmd MyAutoCmd FileType sql call s:sql_my_settings()
function! s:sql_my_settings() abort
endfunction

function! MySqlOmniFunc(findstart, base)
  call sqlcomplete#Map('syntax')
  call sqlcomplete#Complete(a:findstart, a:base)
endfunction

augroup GitSpellCheck
  autocmd!
  autocmd FileType gitcommit setlocal spell
augroup END

"--------------------------------------------
"Absolutely fantastic function from stoeffel/.dotfiles which allows you to
"repeat macros across a visual range
"--------------------------------------------
" TMUXと干渉しているので実際は二回押す
nmap <C-q> @q
xnoremap @ :<C-u>call ExecuteMacroOverVisualRange()<CR>
function! ExecuteMacroOverVisualRange()
  echo '@'.getcmdline()
  execute ":'<,'>normal @".nr2char(getchar())
endfunction

" set working directory to the current buffer's directory
nnoremap cd :lcd %:p:h<bar>pwd<cr>
nnoremap cu :lcd ..<bar>pwd<cr>

function! s:ctrl_u() abort "{{{ rsi ctrl-u, ctrl-w
  if getcmdpos() > 1
    let @- = getcmdline()[:getcmdpos()-2]
  endif
  return "\<C-U>"
endfunction

function! s:ctrl_w_before() abort
  let s:cmdline = getcmdpos() > 1 ? getcmdline() : ''
  return "\<C-W>"
endfunction

function! s:ctrl_w_after() abort
  if strlen(s:cmdline) > 0
    let @- = s:cmdline[(getcmdpos()-1) : (getcmdpos()-2)+(strlen(s:cmdline)-strlen(getcmdline()))]
  endif
  return ''
endfunction

cnoremap <expr> <C-U> <SID>ctrl_u()
cnoremap <expr> <SID>(ctrl_w_before) <SID>ctrl_w_before()
cnoremap <expr> <SID>(ctrl_w_after) <SID>ctrl_w_after()
cmap <script> <C-W> <SID>(ctrl_w_before)<SID>(ctrl_w_after)
cnoremap <C-Y> <C-R>-
"--------------------------------------------

command! DiffOrig let g:diffline = line('.')
  \ | vert new | set bt=nofile | r # | 0d_
  \ | diffthis | :exe "norm! ".g:diffline."G"
  \ | wincmd p | diffthis | wincmd p
nnoremap <Leader>do :DiffOrig<cr>

" override help command
nmap <F1> :call <SID>help_override()<CR>
vmap <F1> :call <SID>help_override()<CR>
function! s:help_override() abort
  let vtext = s:get_visual_selection()
  let word = expand("<cword>")
  if vtext != ''
    let word = vtext
  endif
  try
    execute 'silent help ' . word
  catch
    echo word . ' is no help text'
  endtry
endfunction

nmap <silent> gK :call <SID>google_search()<CR>
vmap <silent> gK :call <SID>google_search()<CR>
function! s:google_search() abort
  let vtext = s:get_visual_selection()
  let word = expand("<cword>")
  if vtext != ''
    let word = vtext
  endif
  execute 'silent !google-chrome-stable ' .
   \ '"http://www.google.co.jp/search?num=100&q=' . word . '" 2> /dev/null &'
endfunction
function! s:get_visual_selection()
    let [line_start, column_start] = getpos("'<")[1:2]
    let [line_end, column_end] = getpos("'>")[1:2]
    let lines = getline(line_start, line_end)
    if len(lines) == 0
        return ''
    endif
    let lines[-1] = lines[-1][: column_end - (&selection == 'inclusive' ? 1 : 2)]
    let lines[0] = lines[0][column_start - 1:]
    return join(lines, "\n")
endfunction

" ここをTOMLに入れたい
function! Syntax_range_dein() abort
  let start = '^\s*hook_\%('.
  \  'add\|source\|post_source\|post_update'.
  \  '\)\s*=\s*%s'

  call SyntaxRange#Include(printf(start, "'''"), "'''", 'vim', '')
  call SyntaxRange#Include(printf(start, '"""'), '"""', 'vim', '')
endfunction

function! SetLeximaAddRule() abort
  call lexima#add_rule({'char': "'", 'input_after': "'"})
  call lexima#add_rule({'char': "'", 'at': "''\%#", 'input': "'''"})
  call lexima#add_rule({'char': "'", 'at': "\\%#.*[-0-9a-zA-Z_,:\"]", 'input': "'"})
  call lexima#add_rule({'char': "'", 'at': "\\%#'''", 'leave': 3})
  call lexima#add_rule({'char': '<C-h>', 'at': "'\\%#'", 'delete': 1})
  call lexima#add_rule({'char': '<CR>', 'at': "'''\%#'''", 'input_after': '<CR>'})

  call lexima#add_rule({'char': '"', 'input_after': '"'})
  call lexima#add_rule({'char': '"', 'at': "\\%#.*[-0-9a-zA-Z_,:']", 'input': '"'})
  call lexima#add_rule({'char': '"', 'at': '"""\%#', 'input': '"""'})
  call lexima#add_rule({'char': '"', 'at': '\%#"""', 'leave': 3})
  call lexima#add_rule({'char': '<C-h>', 'at': '"\%#"', 'delete': 1})
  call lexima#add_rule({'char': '<CR>', 'at': '"""\%#""")', 'input_after': '<CR>'})

  call lexima#add_rule({'char': "<", 'input_after': ">"})
  call lexima#add_rule({'char': '<', 'at': "\\%#.*[-0-9a-zA-Z_,:\"']", 'input': '<'})
  call lexima#add_rule({'char': '<C-h>', 'at': '<\%#>', 'delete': 1})
  call lexima#add_rule({'char': '<Space>', 'at': '<\%#>', 'input_after': '<Space>'})
  call lexima#add_rule({'char': '<BS>', 'at': '< \%# >', 'delete': 1})

  call lexima#add_rule({'char': "{", 'input_after': "}"})
  call lexima#add_rule({'char': '{', 'at': "\\%#.*[-0-9a-zA-Z_,:\"']", 'input': '{'})
  call lexima#add_rule({'char': '<C-h>', 'at': '{\%#}', 'delete': 1})
  call lexima#add_rule({'char': '<CR>', 'at': '{\%#}', 'input_after': '<CR>'})
  call lexima#add_rule({'char': '<Space>', 'at': '{\%#}', 'input_after': '<Space>'})
  call lexima#add_rule({'char': '<BS>', 'at': '{ \%# }', 'delete': 1})

  call lexima#add_rule({'char': "[", 'input_after': "]"})
  call lexima#add_rule({'char': '[', 'at': "\\%#.*[-0-9a-zA-Z_,:\"']", 'input': '['})
  call lexima#add_rule({'char': '<C-h>', 'at': '\[\%#\]', 'delete': 1})
  call lexima#add_rule({'char': '<CR>', 'at': '\[\%#\]', 'input_after': '<CR>'})
  call lexima#add_rule({'char': '<Space>', 'at': '\[\%#]', 'input_after': '<Space>'})
  call lexima#add_rule({'char': '<BS>', 'at': '\[ \%# ]', 'delete': 1})

  call lexima#add_rule({'char': "(", 'input_after': ")"})
  call lexima#add_rule({'char': '(', 'at': "\\%#.*[-0-9a-zA-Z_,:\"']", 'input': '('})
  call lexima#add_rule({'char': '<C-h>', 'at': '(\%#)', 'delete': 1})
  call lexima#add_rule({'char': '<CR>', 'at': '(\%#)', 'input_after': '<CR>'})
  call lexima#add_rule({'char': '<Space>', 'at': '(\%#)', 'input_after': '<Space>'})
  call lexima#add_rule({'char': '<BS>', 'at': '( \%# )', 'delete': 1})

  call lexima#add_rule({'char': '<C-s>', 'at': '\%#)', 'leave': 1})
  call lexima#add_rule({'char': '<C-s>', 'at': '\%#"', 'leave': 1})
  call lexima#add_rule({'char': '<C-s>', 'at': "\\%#'", 'leave': 1})
  call lexima#add_rule({'char': '<C-s>', 'at': '\%#]', 'leave': 1})
  call lexima#add_rule({'char': '<C-s>', 'at': '\%#}', 'leave': 1})
  call lexima#add_rule({'char': '<C-s>', 'at': '\%# )', 'leave': 1})
  call lexima#add_rule({'char': '<C-s>', 'at': '\%# ]', 'leave': 1})
  call lexima#add_rule({'char': '<C-s>', 'at': '\%# }', 'leave': 1})
endfunction

command!
  \ -nargs=+ -bang
  \ -complete=command
  \ Capture
  \ call s:cmd_capture([<f-args>], <bang>0)

function! C(cmd)
  redir => result
  silent execute a:cmd
  redir END
  return result
endfunction

function! s:cmd_capture(args, banged) "{{{
  new
  silent put =C(join(a:args))
  1,2delete _
endfunction
