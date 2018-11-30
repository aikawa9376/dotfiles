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
let &runtimepath = s:dein_repo_dir .",". &runtimepath
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
set splitbelow
set updatetime=100
set nofoldenable
set foldmethod=indent
set foldcolumn=0
set foldnestmax=1  " maximum fold depth
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
nmap     <Leader>S <Plug>(my-switch)
nnoremap <silent> <Plug>(my-switch)s :<C-u>setl spell! spell?<CR>
nnoremap <silent> <Plug>(my-switch)l :<C-u>setl list! list?<CR>
nnoremap <silent> <Plug>(my-switch)t :<C-u>setl expandtab! expandtab?<CR>
nnoremap <silent> <Plug>(my-switch)w :<C-u>setl wrap! wrap?<CR>
nnoremap <silent> <Plug>(my-switch)p :<C-u>setl paste! paste?<CR>
nnoremap <silent> <Plug>(my-switch)b :<C-u>setl scrollbind! scrollbind?<CR>
nnoremap <silent> <Plug>(my-switch)y :call <SID>toggle_syntax()<CR>
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

" Insertモードのときカーソルの形状を変更
if has('unix')
  if &term =~ "screen"
    let &t_ti.= "\eP\e[1 q\e\\"
    let &t_SI.= "\eP\e[5 q\e\\"
    let &t_EI.= "\eP\e[1 q\e\\"
    let &t_te.= "\eP\e[0 q\e\\"
  elseif &term =~ "xterm"
    let &t_ti.="\e[1 q"
    let &t_SI.="\e[5 q"
    let &t_EI.="\e[1 q"
    let &t_te.="\e[0 q"
  elseif  has('mac')
    let &t_SI = "\<Esc>Ptmux;\<Esc>\<Esc>]50;CursorShape=1\x7\<Esc>\\"
    let &t_EI = "\<Esc>Ptmux;\<Esc>\<Esc>]50;CursorShape=0\x7\<Esc>\\"
  endif
endif

" ファイル処理関連の設定
set confirm    " 保存されていないファイルがあるときは終了前に保存確認
set hidden     " 保存されていないファイルがあるときでも別のファイルを開くことが出来る
set autoread   " 外部でファイルに変更がされた場合は読みなおす
set nobackup   " ファイル保存時にバックアップファイルを作らない
set noswapfile " ファイル編集中にスワップファイルを作らない
set switchbuf=useopen " 新しく開く代わりにすでに開いてあるバッファを開く
nmap <Leader>z :Bonly<CR>
command! -nargs=? -complete=buffer -bang Bonly
    \ :call BufOnly('<args>', '<bang>')
function! BufOnly(buffer, bang)
  if a:buffer == ''
    " No buffer provided, use the current buffer.
    let buffer = bufnr('%')
  elseif (a:buffer + 0) > 0
    " A buffer number was provided.
    let buffer = bufnr(a:buffer + 0)
  else
    " A buffer name was provided.
    let buffer = bufnr(a:buffer)
  endif
  if buffer == -1
    echohl ErrorMsg
    echomsg "No matching buffer for" a:buffer
    echohl None
    return
  endif
  let last_buffer = bufnr('$')
  let delete_count = 0
  let n = 1
  while n <= last_buffer
    if n != buffer && buflisted(n)
      if a:bang == '' && getbufvar(n, '&modified')
        echohl ErrorMsg
        echomsg 'No write since last change for buffer'
              \ n '(add ! to override)'
        echohl None
      else
        silent exe 'bdel' . a:bang . ' ' . n
        if ! buflisted(n)
          let delete_count = delete_count+1
        endif
      endif
    endif
    let n = n+1
  endwhile
  if delete_count == 1
    echomsg delete_count "buffer deleted"
  elseif delete_count > 1
    echomsg delete_count "buffers deleted"
  endif
endfunction

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

" 検索後にジャンプした際に検索単語を画面中央に持ってくる
nnoremap n nzz
nnoremap N Nzz
nnoremap * *zz
nnoremap # #zz
nnoremap g* g*zz
nnoremap g# g#zz

" スクロール時に表示を10行確保
set scrolloff=10

" x キー削除でデフォルトレジスタに入れない
nnoremap x "_x
vnoremap x "_x
nnoremap s "_s
vnoremap s "_s
nmap <M-p> o<ESC>p==
nmap gV `[v`]

" ヤンクした後に末尾に移動
nmap <silent><C-t> :<C-u>call YankTextToggle()<CR>
function! YankTextToggle()
  let s:flag = b:yank_toggle_flag ? 1 : 0
  if b:yank_toggle_flag != 0
    execute 'normal `['
    let b:yank_toggle_flag = 0
  else
    execute 'normal `]'
    let b:yank_toggle_flag = 1
  endif
endfunction
function! s:yank_toggle_flag() abort
  let b:yank_toggle_flag = 0
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
" nnoremap <Leader><CR> $a<CR><Esc>
nnoremap <M-d> mzo<ESC>`zj
nnoremap <M-u> mzO<ESC>`zk

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

" 文字選択・移動など
nnoremap Y y$
" nnoremap V v$
nnoremap <C-h> ^
nnoremap <C-l> $
nnoremap <silent><C-g> :call cursor(0,strlen(getline("."))/2)<CR>
nnoremap <C-e> 10<C-e>
nnoremap <C-y> 10<C-y>
" すごく移動する
nnoremap <C-j> 10j
nnoremap <C-k> 10k

" gJで空白を削除する
fun! JoinSpaceless()
    execute 'normal J'
    " Character under cursor is whitespace?
    if matchstr(getline('.'), '\%' . col('.') . 'c.') =~ '\s'
        " When remove it!
        execute 'normal dw'
    endif
endfun
nnoremap gJ :call JoinSpaceless()<CR>

" j, k による移動を折り返されたテキストでも自然に振る舞うように変更
nnoremap j gj
nnoremap k gk

" コマンドモードでemacs
cnoremap <C-b> <Left>
cnoremap <C-f> <Right>
cnoremap <C-n> <Down>
cnoremap <C-p> <Up>
cnoremap <C-a> <Home>
cnoremap <C-e> <End>
cnoremap <C-d> <Del>
cnoremap <C-k> <C-o>D<Right>

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
set wildmenu wildmode=list:full "コマンドモード補完

" 入力モード中に素早くJJと入力した場合はESCとみなす
inoremap <silent> jj <Esc>

" ペーストモードを自動解除
autocmd InsertLeave * set nopaste
nnoremap Q q

" ジャンプリストで中央に持ってくる
nnoremap <C-o> <C-o>zz
nnoremap <C-i> <C-i>zz
nnoremap g; g;zz
nnoremap g, g,zz
nnoremap <C-u> <C-u>zz
nnoremap <C-d> <C-d>zz
nnoremap <C-f> <C-f>zz
nnoremap <C-b> <C-b>zz

" ファイル操作系
nmap <Leader> <Nop>
nmap <Leader>w :<c-u>w<CR>
nmap <Leader>x :<c-u>bd<CR>
nmap <Leader>q :<c-u>wq<CR>
nmap <silent> <M-b> :bprevious<CR>
nmap <silent> <M-f> :bnext<CR>
" QuickFixおよびHelpでは q でバッファを閉じる
autocmd MyAutoCmd FileType help,qf nnoremap <buffer> q <C-w>cbnext<CR>

" window操作系
nmap <silent> \| :<c-u>vsplit<CR>
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

" ctags
set tags=./tags,tags;$HOME
function! s:execute_ctags() abort
  " 探すタグファイル名
  let tag_name = 'tags'
  " ディレクトリを遡り、タグファイルを探し、パス取得
  let tags_path = findfile(tag_name, '.;')
  " タグファイルパスが見つからなかった場合
  if tags_path ==# ''
    return
  endif
  " タグファイルのディレクトリパスを取得
  " `:p:h`の部分は、:h filename-modifiersで確認
  let tags_dirpath = fnamemodify(tags_path, ':p:h')
  " 見つかったタグファイルのディレクトリに移動して、ctagsをバックグラウンド実行（エラー出力破棄）
  execute 'silent !cd' tags_dirpath '&& ctags -R -f' tag_name '2> /dev/null &'
endfunction

augroup ctags
  autocmd!
  autocmd BufWritePost * call s:execute_ctags()
augroup END

" vimrcをスペースドットで開く
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

" ここをTOMLに入れたい
function! Syntax_range_dein() abort
  let start = '^\s*hook_\%('.
  \           'add\|source\|post_source\|post_update'.
  \           '\)\s*=\s*%s'

  call SyntaxRange#Include(printf(start, "'''"), "'''", 'vim', '')
  call SyntaxRange#Include(printf(start, '"""'), '"""', 'vim', '')
endfunction

function! SetLeximaAddRule() abort
  call lexima#add_rule({'at': '\%#.*[-0-9a-zA-Z_,:]', 'char': "'", 'input': "'"})
  call lexima#add_rule({'at': "\\%#\\n\\s*'", 'char': "'", 'input': "'", 'delete': "'"})
  call lexima#add_rule({'char': '<C-h>', 'at': "'\\%#'", 'delete': 1})

  call lexima#add_rule({'at': '\%#.*[-0-9a-zA-Z_,:]', 'char': '{', 'input': '{'})
  call lexima#add_rule({'at': '\%#\n\s*}', 'char': '}', 'input': '}', 'delete': '}'})
  call lexima#add_rule({'char': '<C-h>', 'at': '{\%#}', 'delete': 1})

  call lexima#add_rule({'at': '\%#.*[-0-9a-zA-Z_,:]', 'char': '[', 'input': '['})
  call lexima#add_rule({'at': '\%#\n\s*\]', 'char': ']', 'input': ']', 'delete': ']'})
  call lexima#add_rule({'char': '<C-h>', 'at': '\[\%#\]', 'delete': 1})

  call lexima#add_rule({'at': '\%#.*[-0-9a-zA-Z_,:]', 'char': '(', 'input': '('})
  call lexima#add_rule({'at': '\%#\n\s*)', 'char': ')', 'input': ')', 'delete': ')'})
  call lexima#add_rule({'char': '<C-h>', 'at': '(\%#)', 'delete': 1})

  call lexima#add_rule({'at': '\%#.*[-0-9a-zA-Z_,:]', 'char': '"', 'input': '"'})
  call lexima#add_rule({'at': '\%#\n\s*"', 'char': '"', 'input': '"', 'delete': '"'})
  call lexima#add_rule({'char': '<C-h>', 'at': '"\%#"', 'delete': 1})

  call lexima#add_rule({'char': '<TAB>', 'at': '\%#)', 'leave': 1})
  call lexima#add_rule({'char': '<TAB>', 'at': '\%#"', 'leave': 1})
  call lexima#add_rule({'char': '<TAB>', 'at': "\\%#'", "leave": 1})
  call lexima#add_rule({'char': '<TAB>', 'at': '\%#]', 'leave': 1})
  call lexima#add_rule({'char': '<TAB>', 'at': '\%#}', 'leave': 1})
endfunction

" php用の設定はここ
autocmd FileType php,phml call s:php_my_settings()
function! s:php_my_settings() abort
  inoremap <buffer> <M--> ->
  inoremap <buffer> <M-=> =>
  nnoremap <buffer> <expr><F1> IsPhpOrHtml() ? ":set ft=html<CR>" : ":set ft=php<CR>"
  nnoremap <buffer> <M-4> bi$<ESC>e
  " let b:match_words .= ',if.*(.*)\s{:selse\s{:},?php:?>,for:},if:endif,foreach:endforeach'
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

" test settings
" 親ディレクトリを開く netrw有効なら便利かも
" nnoremap <silent> <C-u> :execute 'e ' . ((strlen(bufname('')) == 0) ? '.' : '%:h')<CR>
vmap p <Plug>(operator-replace)
" nnoremap <space>9 V%y<C-w>jGpkVGJ

"--------------------------------------------
"Absolutely fantastic function from stoeffel/.dotfiles which allows you to
"repeat macros across a visual range
"--------------------------------------------
xnoremap @ :<C-u>call ExecuteMacroOverVisualRange()<CR>
function! ExecuteMacroOverVisualRange()
  echo "@".getcmdline()
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
  let s:cmdline = getcmdpos() > 1 ? getcmdline() : ""
  return "\<C-W>"
endfunction

function! s:ctrl_w_after() abort
  if strlen(s:cmdline) > 0
    let @- = s:cmdline[(getcmdpos()-1) : (getcmdpos()-2)+(strlen(s:cmdline)-strlen(getcmdline()))]
  endif
  return ""
endfunction

cnoremap <expr> <C-U> <SID>ctrl_u()
cnoremap <expr> <SID>(ctrl_w_before) <SID>ctrl_w_before()
cnoremap <expr> <SID>(ctrl_w_after) <SID>ctrl_w_after()
cmap <script> <C-W> <SID>(ctrl_w_before)<SID>(ctrl_w_after)
cnoremap <C-Y> <C-R>-
"--------------------------------------------

" override help command
nnoremap <F1> <C-\><C-N>:help <C-R><C-W><CR>

