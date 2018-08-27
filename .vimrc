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
call dein#add('Shougo/deoplete.nvim') 
if !has('nvim')
  call dein#add('roxma/nvim-yarp')
  call dein#add('roxma/vim-hug-neovim-rpc')
endif
if has('job') && has('channel') && has('timers')
  call dein#add('w0rp/ale')
else
  call dein#add('vim-syntastic/syntastic')
endif
call dein#add('Shougo/neosnippet')
call dein#add('Shougo/neosnippet-snippets')
call dein#add('Shougo/denite.nvim')
call dein#add('vim-scripts/taglist.vim')
call dein#add('tpope/vim-surround')
call dein#add('terryma/vim-multiple-cursors')
call dein#add('vim-airline/vim-airline')
call dein#add('mattn/emmet-vim')
call dein#add('Townk/vim-autoclose')
call dein#add('scrooloose/nerdtree')
call dein#add('altercation/vim-colors-solarized')
call dein#add('junegunn/fzf', { 'build': './install', 'merged': 0 })
call dein#add('junegunn/fzf.vim', { 'depends': 'fzf' })
call dein#add('pangloss/vim-javascript')

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

let g:deoplete#enable_at_startup = 1

" Snippet key-mappings.
" Note: It must be "imap" and "smap".  It uses <Plug> mappings.
imap <C-s> <Plug>(neosnippet_expand_or_jump)
smap <C-s> <Plug>(neosnippet_expand_or_jump)
xmap <C-s> <Plug>(neosnippet_expand_target)

" For conceal markers.
if has('conceal')
  set conceallevel=2 concealcursor=niv
endif

" lint
let g:ale_fixers = {}
let g:ale_fixers['javascript'] = ['prettier-eslint']
let g:ale_fixers['html'] = ['prettier']
let g:ale_fixers['css'] = ['prettier']
let g:ale_fixers['scss'] = ['prettier']
let g:ale_fixers['php'] = ['prettier']
" ファイル保存時に実行
let g:ale_fix_on_save = 1
" ローカルの設定ファイルを考慮する
let g:ale_javascript_prettier_use_local_config = 1

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

" ファイル処理関連の設定
set confirm    " 保存されていないファイルがあるときは終了前に保存確認
set hidden     " 保存されていないファイルがあるときでも別のファイルを開くことが出来る
set autoread   "外部でファイルに変更がされた場合は読みなおす
set nobackup   " ファイル保存時にバックアップファイルを作らない
set noswapfile " ファイル編集中にスワップファイルを作らない

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
set smartindent
nnoremap <Space>l gg=G

"ノーマルモード中にEnterで改行
nnoremap <CR> i<CR><Esc>
nnoremap <Space>d mzo<ESC>`z
nnoremap <Space>u mzO<ESC>`z

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

nnoremap <C-h> ^
nnoremap <C-l> $

"j, k による移動を折り返されたテキストでも自然に振る舞うように変更
nnoremap j gj
nnoremap k gk

"行末の1文字先までカーソルを移動できるように
set virtualedit=onemore

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
runtime macros/matchit.vim
let b:match_words = "if:endif,foreach:endforeach,\<begin\>:\<end\>"
nnoremap <Tab> %
vnoremap <Tab> %
nmap <silent> <Tab>x :close<CR>
nmap <silent> <Tab>c :close<CR>
nmap <silent> <Tab>h gT
nmap <silent> <Tab>l gt
nmap <silent> <Tab>L :+tabmove<CR>
nmap <silent> <Tab>H :-tabmove<CR>

"入力モード中に素早くJJと入力した場合はESCとみなす
inoremap <silent> jj <Esc>

"ジャンプリストで中央に持ってくる
nnoremap <C-o> <C-o>zz
nnoremap <C-i> <C-i>zz

"emmet
let g:user_emmet_install_global = 0
autocmd FileType phtml,html,php,css EmmetInstall
imap <silent> <Tab> <C-y>,

"ファイル操作系
map <Space> <Nop>
map <Space>w :<c-u>w<CR>
nnoremap <Space>q :<c-u>wq<CR>
nnoremap <Space>n :NERDTreeToggle<CR>

"前回のカーソル位置からスタート
augroup vimrcEx
  au BufRead * if line("'\"") > 0 && line("'\"") <= line("$") |
        \ exe "normal g`\"" | endif
augroup END

"fzf
nnoremap <Space>f :Files<CR>
nnoremap <Space>b :Buffers<CR>
nnoremap <Space>a :Ag<CR>

"ctags
nnoremap <Space>o :TlistToggle<CR>

"vimrcをスペースドットで開く
nnoremap <Space>. :<c-u>e ~/.vimrc<CR>
"nnoremap <C-2> :<c-u>source ~\.vimrc<CR>
