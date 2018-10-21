if !&compatible
  set nocompatible
endif

" reset augroup
augroup MyAutoCmd
  autocmd!
augroup END

" dein settings {{{
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
" }}}

" Required:
filetype on
filetype plugin indent on
syntax enable
set t_Co=256

set number
set backspace=indent,eol,start
set encoding=utf-8
" set ambiwidth=double
set fileformats=unix,dos,mac
set fileencodings=utf-8,sjis
set redrawtime=10000
set ttimeoutlen=10
set completeopt=menuone
set noshowmode
" set colorcolumn=120
" set spell
" set spelllang=en,cjk
" set cursorcolumn

" functions
command! -nargs=*
      \   Debug
      \   try
      \|      echom <q-args> ":" string(<args>)
      \|  catch
        \|      echom <q-args>
        \|  endtry

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

" 検索をファイルの先頭へ循環しない
set nowrapscan

" 大文字小文字の区別なし
set ignorecase
set smartcase

" 検索語句をハイライト ESC二回でオフ
set incsearch
set inccommand=split
set hlsearch
nmap <silent> <Esc><Esc> :nohlsearch<CR>

" すごく移動する
nnoremap <C-j> 10j
nnoremap <C-k> 10k

" 検索後にジャンプした際に検索単語を画面中央に持ってくる
nnoremap zz zz10<C-e>
nnoremap n nzz10<C-e>
nnoremap N Nzz10<C-e>
nnoremap * *zz10<C-e>
nnoremap # #zz10<C-e>
nnoremap g* g*zz10<C-e>
nnoremap g# g#zz10<C-e>

" スクロール時に表示を10行確保
set scrolloff=10

" 半画面スクロールで位置を真ん中に
nnoremap <C-u> <C-u>zz
nnoremap <C-d> <C-d>zz10<C-e>
nnoremap } }zz10<C-e>
nnoremap { {zz10<C-e>
nnoremap ) )zz10<C-e>
nnoremap ( (zz10<C-e>

" x キー削除でデフォルトレジスタに入れない
nnoremap x "_x
vnoremap x "_x
nnoremap s "_s
vnoremap s "_s
" ヤンクした後に末尾に移動
nmap <C-t> `]

" 選択範囲のインデントを連続して変更
vnoremap < <gv
vnoremap > >gv
set smartindent
nnoremap <Space>i mzgg=G`z

" ノーマルモード中にEnterで改行
nnoremap <CR> i<CR><Esc>
nnoremap <M-d> mzo<ESC>`zj
nnoremap <M-u> mzO<ESC>`zk

" インサートモードで bash 風キーマップ
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

" terminal mode
set splitbelow
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

" タブの設定
" TABにて対応ペアにジャンプ
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

" 入力モード中に素早くJJと入力した場合はESCとみなす
inoremap <silent> jj <Esc>

" ペーストモードを自動解除
autocmd InsertLeave * set nopaste

" ジャンプリストで中央に持ってくる
nnoremap <C-o> <C-o>zz10<C-e>
nnoremap <C-i> <C-i>zz10<C-e>
nnoremap g; g;zz10<C-e>
nnoremap g, g,zz10<C-e>

" ファイル操作系
nmap <Space> <Nop>
nmap <Space>w :<c-u>w<CR>
nmap <Space>x :<c-u>bd<CR>
nmap <Space>q :<c-u>wq<CR>
nmap <silent> <M-b> :bprevious<CR>
nmap <silent> <M-f> :bnext<CR>

" 前回のカーソル位置からスタート
augroup vimrcEx
  au BufRead * if line("'\"") > 0 && line("'\"") <= line("$") |
        \ exe "normal g`\"" | endif
augroup END

" セミコロンを付けて改行
function! IsEndSemicolon()
  let c = getline(".")[col("$")-2]
  if c != ';'
    return 1
  else
    return 0
  endif
endfunction
nnoremap <expr><Space><CR> IsEndSemicolon() ? "i<C-O>$;<CR><ESC>" : "i<C-O>$<CR><ESC>"
" inoremap <expr><Space><CR> IsEndSemicolon() ? "<C-O>$;<CR>" : "<C-O>$<CR>"

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
  " execute '!cd' tags_dirpath '&& ctags -R -f' tag_name ' &'
  execute 'silent !cd' tags_dirpath '&& ctags -R -f' tag_name '2> /dev/null &'
endfunction

augroup ctags
  autocmd!
  autocmd BufWritePost * call s:execute_ctags()
augroup END

" vimrcをスペースドットで開く
" nnoremap <silent> <Space>. :<c-u>e ~/.config/nvim/init.vim<CR>
nnoremap <Space>, :<c-u>w<CR>:<c-u>source ~/.config/nvim/init.vim<CR>

" 固有のvimrcを用意　.vimrc.local
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
endfunction
