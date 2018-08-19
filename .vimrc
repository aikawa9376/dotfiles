"dein Scripts-----------------------------
if &compatible
  set nocompatible 
endif

" Required:
set runtimepath+=~/.vim/bundle/repos/github.com/Shougo/dein.vim

" Required:
call dein#begin(expand('~/.vim/bundle'))

" Let dein manage dein
" Required:
call dein#add('Shougo/dein.vim')

" Add or remove your plugins here:
call dein#add('Shougo/neosnippet.vim')
call dein#add('Shougo/neosnippet-snippets')
call dein#add('Shougo/deoplete.nvim')
call dein#add('Shougo/denite.nvim')
call dein#add('tpope/vim-surround')
call dein#add('terryma/vim-multiple-cursors')
call dein#add('vim-airline/vim-airline')
call dein#add('mattn/emmet-vim')
call dein#add('Townk/vim-autoclose')
call dein#add('scrooloose/nerdtree')
call dein#add('altercation/vim-colors-solarized')
call dein#add('junegunn/fzf', { 'build': './install --all', 'merged': 0 })
call dein#add('junegunn/fzf.vim', { 'depends': 'fzf' })

" You can specify revision/branch/tag.
call dein#add('Shougo/vimshell', { 'rev': '3787e5' })

" Required:
call dein#end()

" Required:
filetype plugin indent on

" If you want to install not installed plugins on startup.
if dein#check_install()
  call dein#install()
endif

"End dein Scripts-------------------------

set number
set background=dark
set backspace=indent,eol,start
syntax enable
let g:solarized_termcolors=256
colorscheme solarized

" multiple_cursorsの設定
set <M-n>=<ESC>n
map <ESC>n <M-n>
set <M-S-n>=<ESC>N
map <ESC>N <M-S-n>

function! Multiple_cursors_before()
  if exists(':NeoCompleteLock')==2
    exe 'NeoCompleteLock'
  endif
endfunction

function! Multiple_cursors_after()
  if exists(':NeoCompleteUnlock')==2
    exe 'NeoCompleteUnlock'
  endif
endfunction

" Insertモードのときカーソルの形状を変更
let &t_SI = "\<Esc>]50;CursorShape=1\x7"
let &t_EI = "\<Esc>]50;CursorShape=0\x7"
inoremap <Esc> <Esc>

"検索をファイルの先頭へ循環しない
set nowrapscan

"大文字小文字の区別なし
set ignorecase
set smartcase

""検索語句をハイライト ESC二回でオフ
set incsearch
set hlsearch
nmap <silent> <Esc><Esc> :nohlsearch<CR>

"検索後にジャンプした際に検索単語を画面中央に持ってくる
nnoremap n nzz
nnoremap N Nzz
nnoremap * *zz
nnoremap # #zz
nnoremap g* g*zz
nnoremap g# g#zz

"スクロール時に表示を10行確保
set scrolloff=10

"半画面スクロールで位置を真ん中に
nnoremap <C-u> <C-u>zz
nnoremap <C-d> <C-d>zz
nnoremap <S-}> <S-}>zz
nnoremap <S-{> <S-{>zz
nnoremap <S-)> <S-)>zz
nnoremap <S-(> <S-(>zz
nnoremap <Space>j 4jzz
nnoremap <Space>k 4kzz

"x キー削除でデフォルトレジスタに入れない
nnoremap x "_x
vnoremap x "_x

"vv で行末まで選択
vnoremap v ^$h

"選択範囲のインデントを連続して変更
vnoremap < <gv
vnoremap > >gv

"ノーマルモード中にEnterで改行
noremap <CR> i<CR><Esc>

"インサートモードで bash 風キーマップ
inoremap <C-a> <C-o>^
inoremap <C-e> <C-o>$<Right>
inoremap <C-b> <Left>
inoremap <C-f> <Right>
inoremap <C-n> <Down>
inoremap <C-p> <Up>
inoremap <C-h> <BS>
inoremap <C-d> <Del>
inoremap <C-k> <C-o>D<Right>
inoremap <C-u> <C-o>d^
inoremap <C-w> <C-o>db

"j, k による移動を折り返されたテキストでも自然に振る舞うように変更
nnoremap j gj
nnoremap k gk

"vを二回で行末まで選択
vnoremap v $h

"動作環境との統合
"OSのクリップボードをレジスタ指定無しで Yank, Put 出来るようにする
set clipboard=unnamed,unnamedplus

"screen利用時設定
set ttymouse=xterm

"マウスの入力を受け付ける
set mouse=a

"tab/indentの設定
set shellslash
set expandtab "タブ入力を複数の空白入力に置き換える
set tabstop=2 "画面上でタブ文字が占める幅
set shiftwidth=2 "自動インデントでずれる幅
set softtabstop=2
"連続した空白に対してタブキーやバックスペースキーでカーソルが動く幅
set autoindent "改行時に前の行のインデントを継続する
set smartindent "改行時に入力された行の末尾に合わせて次の行のインデントを増減する
set wildmenu wildmode=list:full "コマンドモード補完

"タブの設定
"TABにて対応ペアにジャンプ
nnoremap <Tab> %
vnoremap <Tab> %
map <silent> <Tab>x :close<CR>
map <silent> <Tab>c :close<CR>
map <silent> <Tab>h gT
map <silent> <Tab>l gt
map <silent> <Tab>L :+tabmove<CR>
map <silent> <Tab>H :-tabmove<CR>

"入力モード中に素早くJJと入力した場合はESCとみなす
inoremap <silent> jj <Esc>

"ファイル操作系
map <Space> <Nop>
map <Space>w :<c-u>w<CR>
nnoremap <Space>q :<c-u>wq<CR>
nnoremap <Space>n :NERDTreeToggle<CR>

"vimrcをスペースドットで開く
nnoremap <C-1> :<c-u>e ~\.vimrc<CR>
"nnoremap <C-2> :<c-u>source ~\.vimrc<CR>
