set encoding=utf-8
scriptencoding utf-8

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
" 高速アップデート用設定
source $XDG_CONFIG_HOME/nvim/dein_key.vim

" Required:
filetype on
filetype plugin indent on
syntax enable
set t_Co=256
set number
set fillchars+=vert:\ 
set backspace=indent,eol,start
set fileformats=unix,dos,mac
set fileencodings=utf-8,sjis
set ttimeoutlen=1
set completeopt=menuone
set noshowmode
set cursorline
set list
set undofile
set undodir=$XDG_CACHE_HOME/nvim/undo/
set listchars=tab:»-,extends:»,precedes:«,nbsp:%,trail:-
set splitright
set splitbelow
set updatetime=100
set nospell
set spelllang=en,cjk
set shortmess+=atc
set signcolumn=yes

" ファイル処理関連の設定
set confirm           " 保存されていないファイルがあるときは終了前に保存確認
set hidden            " 保存されていないファイルがあるときでも別のファイルを開くことが出来る
set autoread          " 外部でファイルに変更がされた場合は読みなおす
set nobackup          " ファイル保存時にバックアップファイルを作らない
set nowritebackup     " ファイル保存時にバックアップファイルを作らない
set noswapfile        " ファイル編集中にスワップファイルを作らない
set switchbuf=useopen " 新しく開く代わりにすでに開いてあるバッファを開く

" 大文字小文字の区別なし
set ignorecase
set smartcase

" 検索語句をハイライト ESC二回でオフ
set incsearch
set inccommand=split
set hlsearch

" インデント
set smartindent
set breakindent

" スクロール時に表示を10行確保
set scrolloff=10

" 行末の1文字先までカーソルを移動できるように
set virtualedit=onemore

" 動作環境との統合
" OSのクリップボードをレジスタ指定無しで Yank, Put 出来るようにする
set clipboard=unnamed,unnamedplus

" マウスの入力を受け付ける
set mouse=a

" tab/indentの設定
set shellslash
set expandtab    " タブ入力を複数の空白入力に置き換える
set tabstop=2    " 画面上でタブ文字が占める幅
set shiftwidth=2 " 自動インデントでずれる幅
set softtabstop=2
set autoindent   " 改行時に前の行のインデントを継続する
set smartindent  " 改行時に入力された行の末尾に合わせて次の行のインデントを増減する
" set wildmenu wildmode=list,full "コマンドモード補完
set wildoptions+=pum
set pumblend=20
set winblend=20

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

" Insertモードのときカーソルの形状を変更
if has('unix')
  if &term =~? 'screen'
    let &t_ti.= "\eP\e[1 q\e\\"
    let &t_SI.= "\eP\e[5 q\e\\"
    let &t_EI.= "\eP\e[1 q\e\\"
    let &t_te.= "\eP\e[0 q\e\\"
  elseif &term =~? 'xterm'
    let &t_ti.="\e[1 q"
    let &t_SI.="\e[5 q"
    let &t_EI.="\e[1 q"
    let &t_te.="\e[0 q"
  elseif  has('mac')
    let &t_SI = "\<Esc>Ptmux;\<Esc>\<Esc>]50;CursorShape=1\x7\<Esc>\\"
    let &t_EI = "\<Esc>Ptmux;\<Esc>\<Esc>]50;CursorShape=0\x7\<Esc>\\"
  endif
endif

nmap <Space> <Leader>
vmap <Space> <Leader>
xmap <Space> <Leader>
omap <Space> <Leader>

noremap  <Plug>(my-switch) <Nop>
nmap     <Leader>t <Plug>(my-switch)
nnoremap <silent> <Plug>(my-switch)s :<C-u>setl spell! spell?<CR>
nnoremap <silent> <Plug>(my-switch)l :<C-u>setl list! list?<CR>
nnoremap <silent> <Plug>(my-switch)t :<C-u>setl expandtab! expandtab?<CR>
nnoremap <silent> <Plug>(my-switch)w :<C-u>setl wrap! wrap?<CR>
nnoremap <silent> <Plug>(my-switch)p :<C-u>setl paste! paste?<CR>
nnoremap <silent> <Plug>(my-switch)b :<C-u>setl scrollbind! scrollbind?<CR>

nmap <Leader>z :BufOnly<CR>

" x キー削除でデフォルトレジスタに入れない
nnoremap x "_x
vnoremap x "_x
nnoremap cl "_s
vnoremap cl "_s

nmap <silent><expr> gV '`['.strpart(getregtype(), 0, 1).'`]'

" 選択範囲のインデントを連続して変更
vnoremap < <gv
vnoremap > >gv
nnoremap <Leader>i mzgg=G`z

" ノーマルモード中にEnterで改行
nnoremap <CR> i<CR><Esc>==
nnoremap <Leader><CR> $a<CR><Esc>
nnoremap <Leader>s i<Space><ESC>
nnoremap ]<space> mzo<ESC>`zj
nnoremap [<space> mzO<ESC>`zk
nnoremap X diw

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
inoremap <M-f> <C-g>U<C-o>w
inoremap <M-b> <C-g>U<C-o>b
inoremap <M-p> <C-g>U<C-o>P
" TODO undoきれなくする 関数？
inoremap <C-v> <C-g>U<C-o>yh<C-g>U<C-r>"<C-g>U<Right>

" 文字選択・移動など
nnoremap Y y$
nnoremap V v$
nnoremap vv V
nnoremap gV `[v`]
" mrは operator replace用
nnoremap y m`mvmry
vnoremap y m`mvmry
nnoremap v m`mvv
nnoremap d m`mvd
nnoremap c m`mvc
nnoremap : m`mv:
nnoremap = m`mv=
nnoremap <C-v> mv<C-v>
nnoremap <M-x> vy
nnoremap <C-h> ^
vnoremap <C-h> ^
nnoremap <C-l> $l
vnoremap <C-l> $l
nnoremap <silent><M-m> :call cursor(0,strlen(getline("."))/2)<CR>
nnoremap <M-l> i<Space><ESC><Right>
nnoremap <M-h> hx
nnoremap <silent><M-j> j:call cursor(0,strlen(getline("."))/2)<CR>
nnoremap <silent><M-k> k:call cursor(0,strlen(getline("."))/2)<CR>
nnoremap ]n ngn<ESC>
nnoremap [n Ngn<ESC>

nnoremap gj J

" terminal mode
tnoremap <silent><C-[> <C-\><C-n>

" 入力モード中に素早くJJと入力した場合はESCとみなす
inoremap <silent> jj <Esc>
inoremap <silent> っｊ <Esc>
nnoremap <silent> <expr> っｊ Fcitx2en()

" 検索後にジャンプした際に検索単語を画面中央に持ってくる
nnoremap n nzz
nnoremap N Nzz

" ファイル操作系
nmap <Leader> <Nop>
nmap <silent> <Leader>w :<c-u>w<CR>
nmap <silent> <Leader>W :bufdo! w<CR>
nmap <silent> <Leader>x :<c-u>Bdelete<CR>
nmap <silent> <Leader>X :<c-u>bd<CR>
nmap ZZ :<c-u>xa<CR>
nmap <silent> <M-b> :bnext<CR>
nmap <silent> <C-g> m`<C-^>

" window操作系
nmap <silent> \| :<c-u>vsplit<CR><C-w>h
nmap <silent> - :<c-u>split<CR><C-w>k

" 文末に○○を付ける
nnoremap <M-;> mz$a;<ESC>`z
nnoremap <M-,> mz$a,<ESC>`z

" 補完系
inoremap <C-l> <C-x><C-l>

nmap <C-q> @q

" set working directory to the current buffer's directory
nnoremap cd :lcd %:p:h<bar>pwd<cr>
nnoremap cu :lcd ..<bar>pwd<cr>

" コマンドモードでemacs
cnoremap <C-b> <Left>
cnoremap <C-f> <Right>
cnoremap <C-n> <Down>
cnoremap <C-p> <Up>
cnoremap <C-a> <Home>
cnoremap <C-e> <End>
cnoremap <C-d> <Del>
cnoremap <C-Y> <C-R>-
if &wildoptions =~# "pum"
  cnoremap <expr> <C-p> pumvisible() ? '<Left>' : '<C-p>'
  cnoremap <expr> <C-n> pumvisible() ? '<Right>' : '<C-n>'
endif

" override help command

nmap <Leader>rw :%s///g<Left><Left><Left>
nmap <Leader>rW :%s/<c-r>=expand("<cword>")<cr>//g<Left><Left>
vmap <Space>rw y:%s/<c-r>"//g<Left><Left><Left>

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
  call lexima#add_rule({'char': "'", 'at': "\\%#.[-0-9a-zA-Z_,:\"]", 'input': "'"})
  call lexima#add_rule({'char': "'", 'at': "\\%#'''", 'leave': 3})
  call lexima#add_rule({'char': '<C-h>', 'at': "'\\%#'", 'delete': 1})
  call lexima#add_rule({'char': '<CR>', 'at': "'''\%#'''", 'input_after': '<CR>'})

  call lexima#add_rule({'char': '"', 'input_after': '"'})
  call lexima#add_rule({'char': '"', 'at': "\\%#.[-0-9a-zA-Z_,:']", 'input': '"'})
  call lexima#add_rule({'char': '"', 'at': '"""\%#', 'input': '"""'})
  call lexima#add_rule({'char': '"', 'at': '\%#"""', 'leave': 3})
  call lexima#add_rule({'char': '<C-h>', 'at': '"\%#"', 'delete': 1})
  call lexima#add_rule({'char': '<CR>', 'at': '"""\%#""")', 'input_after': '<CR>'})

  call lexima#add_rule({'char': '<', 'input_after': '>'})
  call lexima#add_rule({'char': '<', 'at': "\\%#[-0-9a-zA-Z]", 'input': '<'})
  call lexima#add_rule({'char': '<C-h>', 'at': '<\%#>', 'delete': 1})
  call lexima#add_rule({'char': '<C-h>', 'at': '< \%# >', 'delete': 1})
  call lexima#add_rule({'char': '<Space>', 'at': '<\%#>', 'input_after': '<Space>'})

  call lexima#add_rule({'char': '{', 'input_after': '}'})
  call lexima#add_rule({'char': '{', 'at': "\\%#[-0-9a-zA-Z]", 'input': '{'})
  call lexima#add_rule({'char': '<C-h>', 'at': '{\%#}', 'delete': 1})
  call lexima#add_rule({'char': '<C-h>', 'at': '{ \%# }', 'delete': 1})
  call lexima#add_rule({'char': '<CR>', 'at': '{\%#}', 'input_after': '<CR>'})
  call lexima#add_rule({'char': '<Space>', 'at': '{\%#}', 'input_after': '<Space>'})

  call lexima#add_rule({'char': '[', 'input_after': ']'})
  call lexima#add_rule({'char': '[', 'at': "\\%#[-0-9a-zA-Z]", 'input': '['})
  call lexima#add_rule({'char': '<C-h>', 'at': '\[\%#\]', 'delete': 1})
  call lexima#add_rule({'char': '<C-h>', 'at': '\[ \%# \]', 'delete': 1})
  call lexima#add_rule({'char': '<CR>', 'at': '\[\%#\]', 'input_after': '<CR>'})
  call lexima#add_rule({'char': '<Space>', 'at': '\[\%#\]', 'input_after': '<Space>'})

  call lexima#add_rule({'char': '(', 'input_after': ')'})
  call lexima#add_rule({'char': '(', 'at': "\\%#[-0-9a-zA-Z]", 'input': '('})
  call lexima#add_rule({'char': '<C-h>', 'at': '(\%#)', 'delete': 1})
  call lexima#add_rule({'char': '<C-h>', 'at': '( \%# )', 'delete': 1})
  call lexima#add_rule({'char': '<CR>', 'at': '(\%#)', 'input_after': '<CR>'})
  call lexima#add_rule({'char': '<Space>', 'at': '(\%#)', 'input_after': '<Space>'})

  call lexima#add_rule({'char': '<CR>', 'at': '>\%#<', 'input_after': '<CR>'})

  call lexima#add_rule({'char': ')', 'at': '\%#)', 'leave': 1})
  call lexima#add_rule({'char': '"', 'at': '\%#"', 'leave': 1})
  call lexima#add_rule({'char': "'", 'at': "\\%#'", 'leave': 1})
  call lexima#add_rule({'char': ']', 'at': '\%#]', 'leave': 1})
  call lexima#add_rule({'char': '}', 'at': '\%#}', 'leave': 1})
  call lexima#add_rule({'char': '>', 'at': '\%#>', 'leave': 1})
  call lexima#add_rule({'char': ')', 'at': '\%# )', 'leave': 2})
  call lexima#add_rule({'char': ']', 'at': '\%# ]', 'leave': 2})
  call lexima#add_rule({'char': '}', 'at': '\%# }', 'leave': 2})
endfunction

" ペーストモードを自動解除
autocmd MyAutoCmd InsertLeave * set nopaste

" 前回のカーソル位置からスタート
augroup MyAutoCmd
  autocmd BufRead * if line("'\"") > 0 && line("'\"") <= line("$") |
    \ exe "normal g`\"" | endif
  " QuickFixおよびHelpでは q でバッファを閉じる
  autocmd FileType help,qf nnoremap <buffer> <CR> <CR>
  autocmd FileType help,qf,fugitive nnoremap <buffer><nowait> q <C-w>c
  autocmd FileType far_vim nnoremap <buffer><nowait> q <C-w>o:tabc<CR>
  autocmd FileType gitcommit nmap <buffer><nowait> q :<c-u>wq<CR>
  autocmd FileType fugitive nnoremap <buffer><Space>gp :<c-u>Gina push<CR><C-w>c
augroup END

" html用の設定はここ
augroup MyXML
  autocmd!
  autocmd Filetype xml inoremap <buffer> </ </<C-x><C-o>
  autocmd Filetype html inoremap <buffer> </ </<C-x><C-o>
  autocmd Filetype phtml inoremap <buffer> </ </<C-x><C-o>
  autocmd Filetype php inoremap <buffer> </ </<C-x><C-o>
augroup END

" php用の設定はここ
autocmd MyAutoCmd FileType php,phtml call s:php_my_settings()
function! s:php_my_settings() abort
  nnoremap <buffer> <expr><F1> IsPhpOrHtml() ? ":set ft=html<CR>" : ":set ft=php<CR>"
  nnoremap <buffer> <M-4> bi$<ESC>e
  nnoremap <silent> <buffer> <F11> :PhpRefactorringMenu()<CR>
endfunction

function! IsPhpOrHtml() abort
  let fe = &filetype
  if fe ==? 'php'
    return 1
  elseif fe ==? 'phtml'
    return 1
  elseif fe ==? 'html'
    return 0
  endif
endfunction

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
