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
call dein#add('Shougo/vimproc', {'build': 'make'})
" Add or remove your plugins here:
call dein#add('Shougo/deoplete.nvim')
call dein#add('w0rp/ale')
" call dein#add('ryanoasis/vim-devicons')

call dein#add('Shougo/neosnippet')
call dein#add('Shougo/neosnippet-snippets')
call dein#add('Shougo/context_filetype.vim')
" call dein#add('Shougo/echodoc.vim')
call dein#add('osyo-manga/vim-precious')
call dein#add('vim-scripts/vim-auto-save')
" text
call dein#add('tpope/vim-surround')
call dein#add('tpope/vim-repeat')
call dein#add('tpope/vim-abolish')
call dein#add('mattn/emmet-vim')
call dein#add('alvan/vim-closetag')
call dein#add('machakann/vim-highlightedyank')
call dein#add('thirtythreeforty/lessspace.vim')
call dein#add('yuratomo/w3m.vim')
" call dein#add('Townk/vim-autoclose')
call dein#add('cohama/lexima.vim')
call dein#add('tyru/caw.vim')
call dein#add('thinca/vim-visualstar')
call dein#add('terryma/vim-multiple-cursors')
call dein#add('terryma/vim-expand-region')
call dein#add('Yggdroot/indentLine')
call dein#add('Lokaltog/vim-easymotion')
" list
call dein#add('scrooloose/nerdtree')
call dein#add('xuyuanp/nerdtree-git-plugin')
call dein#add('junegunn/fzf', { 'build': './install', 'merged': 0 })
call dein#add('junegunn/fzf.vim', { 'depends': 'fzf' })
call dein#add('junegunn/vim-peekaboo')
call dein#add('majutsushi/tagbar')
call dein#add('yegappan/mru')
" git
call dein#add('tpope/vim-fugitive')
call dein#add('airblade/vim-gitgutter')
call dein#add('airblade/vim-rooter')
" desigh
call dein#add('vim-airline/vim-airline')
call dein#add('vim-airline/vim-airline-themes')
call dein#add('NLKNguyen/papercolor-theme')
"call dein#add('edkolev/tmuxline.vim')
" php
call dein#add('StanAngeloff/php.vim')
call dein#add('captbaritone/better-indent-support-for-php-with-html')
" start call ':call deoplete#sources#padawan#InstallServer()'
" add ln /usr/bin/ {$plugin}/padawan-php/bin/padawan and padawan-server
call dein#add('padawan-php/deoplete-padawan', {'build': 'composer install'})
" javascript
call dein#add('pangloss/vim-javascript')
call dein#add('HerringtonDarkholme/yats.vim')
call dein#add('mhartington/nvim-typescript', {'build': './install.sh'})

" You can specify revision/branch/tag.
call dein#add('Shougo/vimshell', { 'rev': '3787e5' })

" Required:
call dein#end()

" Required:
filetype off
filetype plugin indent off

" If you want to install not installed plugins on startup.
if dein#check_install()
  call dein#install()
endif

"End dein Scripts-------------------------

set number
set backspace=indent,eol,start
set encoding=utf-8
" set ambiwidth=double
set fileformats=unix,dos,mac
set fileencodings=utf-8,sjis
set redrawtime=10000
set ttimeoutlen=10
set completeopt=menuone
" set cursorcolumn
syntax enable
"set t_Co = 256
set background=dark
autocmd ColorScheme * highlight Normal ctermbg=none
autocmd ColorScheme * highlight LineNr ctermbg=none
colorscheme PaperColor

" deoplete setup
let g:deoplete#enable_at_startup = 1
let g:deoplete#auto_complete_delay = 0
let g:deoplete#auto_complete_start_length = 1
let g:deoplete#enable_camel_case = 0
let g:deoplete#enable_ignore_case = 0
let g:deoplete#enable_refresh_always = 0
let g:deoplete#enable_smart_case = 1
let g:deoplete#file#enable_buffer_path = 1
let g:deoplete#max_list = 100
let g:deoplete#sources#padawan#server_autostart = 0
let g:deoplete#sources#padawan#add_parentheses = 1

" call deoplete#custom#source('neosnippet', 'rank', 1000)
call deoplete#custom#source('tag', 'min_pattern_length', 4)
call deoplete#custom#source('padawan', 'mark', '[P]')
call deoplete#custom#source('padawan', 'rank', 10)
" call deoplete#custom#option('sources', {
"     \ '_': ['neosnippet', 'buffer', 'tag', 'padawan'],
"     \})

" functions
function! s:find_git_root()
  return system('git rev-parse --show-toplevel 2> /dev/null')[:-2]
endfunction
function! s:with_git_root()
  let root = systemlist('git rev-parse --show-toplevel')[0]
  return v:shell_error ? {} : {'dir': root}
endfunction
command! -nargs=*
      \   Debug
      \   try
      \|      echom <q-args> ":" string(<args>)
      \|  catch
        \|      echom <q-args>
        \|  endtry

" Snippet key-mappings.
" Note: It must be "imap" and "smap".  It uses <Plug> mappings.
imap <C-Space> <Plug>(neosnippet_expand_or_jump)
smap <C-Space> <Plug>(neosnippet_expand_or_jump)
xmap <C-Space> <Plug>(neosnippet_expand_target)

" For conceal markers.
if has('conceal')
  set conceallevel=2 concealcursor=niv
endif

" lint
let g:ale_fixers = {}
let g:ale_fixers['javascript'] = ['prettier-eslint']
let g:ale_fixers['html'] = ['tidy']
let g:ale_fixers['css'] = ['prettier']
let g:ale_fixers['scss'] = ['prettier']
let g:ale_fixers['php'] = ['tidy', 'prettier']
let g:ale_linters = {}
" let g:ale_linters['php'] = ['phan']
" ファイル保存時に実行
let g:ale_fix_on_save = 1
let g:ale_lint_on_text_changed = 0
" ローカルの設定ファイルを考慮する
let g:ale_javascript_prettier_use_local_config = 1
" 設定を見直す必要あり
let g:ale_php_phan_executable = 'vendor/bin/phan'
let g:ale_html_tidy_options = '-config .tidyrc'

" multiple_cursorsの設定
function! Multiple_cursors_before()
  let b:deoplete_disable_auto_complete = 1
endfunction

function! Multiple_cursors_after()
  let b:deoplete_disable_auto_complete = 0
endfunction
" intelljのctrl-wみたいの
nmap - <Plug>(expand_region_expand)
vmap - <Plug>(expand_region_expand)
map <C-s> <Nop>
nmap _ <Plug>(expand_region_shrink)
vmap _ <Plug>(expand_region_shrink)

" Insertモードのときカーソルの形状を変更
if has('mac')
  let &t_SI = "\<Esc>Ptmux;\<Esc>\<Esc>]50;CursorShape=1\x7\<Esc>\\"
  let &t_EI = "\<Esc>Ptmux;\<Esc>\<Esc>]50;CursorShape=0\x7\<Esc>\\"
endif
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
  endif
endif

" 行の最初の文字の前にコメント文字をトグル
nmap <C-_> <Plug>(caw:hatpos:toggle)
vmap <C-_> <Plug>(caw:hatpos:toggle)

" ファイル処理関連の設定
set confirm    " 保存されていないファイルがあるときは終了前に保存確認
set hidden     " 保存されていないファイルがあるときでも別のファイルを開くことが出来る
set autoread   " 外部でファイルに変更がされた場合は読みなおす
set nobackup   " ファイル保存時にバックアップファイルを作らない
set noswapfile " ファイル編集中にスワップファイルを作らない
" set autochdir  " ディレクトリを自動で移動
let g:auto_save = 0 " start auto save disable
nmap <silent> <Space>q :AutoSaveToggle<CR>
let g:auto_save_silent = 1 " silent auto save

"検索をファイルの先頭へ循環しない
set nowrapscan

"大文字小文字の区別なし
set ignorecase
set smartcase

""検索語句をハイライト ESC二回でオフ
set incsearch
set inccommand=split
set hlsearch
nmap <silent> <Esc><Esc> :nohlsearch<CR>

"検索後にジャンプした際に検索単語を画面中央に持ってくる
nnoremap zz zz10<C-e>
nnoremap n nzz10<C-e>
nnoremap N Nzz10<C-e>
nnoremap * *zz10<C-e>
nnoremap # #zz10<C-e>
nnoremap g* g*zz10<C-e>
nnoremap g# g#zz10<C-e>

"スクロール時に表示を10行確保
set scrolloff=10

"半画面スクロールで位置を真ん中に
nnoremap <C-u> <C-u>zz10<C-e>
nnoremap <C-d> <C-d>zz10<C-e>
nnoremap } }zz10<C-e>
nnoremap { {zz10<C-e>
nnoremap ) )zz10<C-e>
nnoremap ( (zz10<C-e>

"x キー削除でデフォルトレジスタに入れない
nnoremap x "_x
vnoremap x "_x
nnoremap s "_s
vnoremap s "_s
" Space pでレジスタ0を指定
nnoremap <Space>p "0p

"選択範囲のインデントを連続して変更
vnoremap < <gv
vnoremap > >gv
set smartindent
nnoremap <Space>i gg=G

"ノーマルモード中にEnterで改行
nnoremap <CR> i<CR><Esc>
nnoremap <M-d> mzo<ESC>`zj
nnoremap <M-u> mzO<ESC>`zk

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

" vを二回で行末まで選択 *multiple_cursorsと競合
" vnoremap v $h

"動作環境との統合
"OSのクリップボードをレジスタ指定無しで Yank, Put 出来るようにする
set clipboard=unnamed,unnamedplus

"win系でもALT-v矩形選択を可能に
nmap <Space>v <C-v>

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

" 入力モード中に素早くJJと入力した場合はESCとみなす
inoremap <silent> jj <Esc>

" ジャンプリストで中央に持ってくる
nnoremap <C-o> <C-o>zz10<C-e>
nnoremap <C-i> <C-i>zz10<C-e>
nnoremap g; g;zz10<C-e>
nnoremap g, g,zz10<C-e>

" emmet
let g:user_emmet_install_global = 0
autocmd FileType phtml,html,php,css EmmetInstall
imap <silent> <Tab> <C-y>,

" eazymotionu
let g:EasyMotion_do_mapping = 0
let g:EasyMotion_smartcase = 1
nmap m <Plug>(easymotion-s2)

" ファイル操作系
nmap <Space> <Nop>
nmap <Space>w :<c-u>w<CR>
nmap <Space>x :<c-u>bd<CR>
" nnoremap <Space>q :<c-u>
" wq<CR>
nmap <silent> <M-h> :bprevious<CR>
nmap <silent> <M-l> :bnext<CR>
nmap <silent> <M-j> :b#<CR>
nnoremap <silent> <Space>n :NERDTreeToggle<CR>
let g:NERDTreeShowHidden = 1
let g:NERDTreeShowBookmarks = 1
let g:NERDTreeMinimalUI = 1

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

"fzf
nnoremap <silent> <Space>F :Files<CR>
nnoremap <silent> <Space>f :ProjectFiles<CR>
nnoremap <silent> <Space>b :Buffers<CR>
nnoremap <silent> <Space>a :Ag<CR>
nnoremap <silent> <Space>A :Rag<CR>
nnoremap <silent> <Space>l :Lines<CR>
nnoremap <silent> <Space>e :History<CR>
" <C-]>でタグ検索
nnoremap <silent> <C-]> :call fzf#vim#tags(expand('<cword>'))<CR>
" fzfからファイルにジャンプできるようにする
let g:fzf_buffers_jump = 1
command! ProjectFiles execute 'Files' s:find_git_root()
command! -bang -nargs=? -complete=dir Files
      \ call fzf#vim#files(<q-args>, fzf#wrap('fzf',
      \ {'options': "--preview 'pygmentize -g {}'"}))
" command! -bang -nargs=* Ag
"     \ call fzf#vim#ag(<q-args>,
"     \  <bang>0 ? fzf#vim#with_preview('up:60%')
"     \    : fzf#vim#with_preview('right:50%:hidden', '?'),
"     \  <bang>0)
" command! -nargs=* Rag
"      \ call fzf#vim#ag(<q-args>, extend(s:with_git_root(),{'down':'~40%'}))
command! -bang -nargs=* Ag
      \call fzf#vim#ag(<q-args>, fzf#wrap('rg',
      \ {'options': "--preview 'pygmentize -g $(cut -d: -f1 <<< {}) | sed -n $(cut -d: -f2 <<< {}),\\$p | head -".&lines."'"}))

" fugitive
nmap <silent> <Space>s :Gstatus<CR>
nmap <silent> <Space>d :Gdiff<CR>
" nmap <silent> <Space>w :Gwrite<CR>
nmap <silent> <Space>r :Gremove<CR>
nmap <silent> <Space>h :Gblame<CR>
" test
nmap <Space>g :call fugitive#detect(@%)<CR>

" airline&&tmuxline
let g:airline_theme = 'minimalist'
let g:airline_powerline_fonts = 1
let g:airline_enable_branch = 1
let g:airline#extensions#ale#enabled = 1
let g:airline_detect_whitespace=0
let g:airline#extensions#whitespace#enabled = 0
let g:Powerline_symbols = 'fancy'
set laststatus=2

if !exists('g:airline_symbols')
  let g:airline_symbols = {}
endif
let g:airline_symbols.linenr = '☰'
let g:airline_symbols.maxlinenr = '㏑'
let g:airline_symbols.branch = '⎇'
let g:airline_symbols.paste = 'ρ'
let g:airline_symbols.spell = 'Ꞩ'
let g:airline_symbols.notexists = 'Ɇ'
let g:airline_symbols.whitespace = 'Ξ'
let g:airline_symbols.crypt = '🔒'
" old vim-powerline symbols
let g:airline_symbols.branch = '⭠'
let g:airline_left_sep = '⮀'
let g:airline_right_sep = '⮂'
let g:airline_left_alt_sep = '⮁'
let g:airline_right_alt_sep = '⮃'
let g:airline_symbols.readonly = '⭤'

let g:airline#extensions#tabline#enabled = 1
let g:airline#extensions#tabline#fnamemod = ':t'

"ctags
nnoremap <silent> <Space>o :TagbarToggle<CR>

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

let g:tagbar_autopreview = 1
let g:tagbar_compact = 1
let g:tagbar_autoshowtag = 1
let g:tagbar_width = 40
let g:tagbar_previewwin_pos = 'rightbelow'
" let g:tagbar_autoclose = 1

"vimrcをスペースドットで開く
nnoremap <silent> <Space>. :<c-u>e ~/.config/nvim/init.vim<CR>
nnoremap <Space>, :<c-u>w<CR>:<c-u>source ~/.config/nvim/init.vim<CR>

" filetype on
filetype on
filetype plugin indent on
if !exists('g:context_filetype#same_filetypes')
  let g:context_filetype#same_filetypes = {}
endif
let g:context_filetype#same_filetypes.php = 'phtml'
let g:context_filetype#same_filetypes.php = 'html'
let g:context_filetype#same_filetypes.html = 'php'
let b:context_filetype_filetypes = context_filetype#default_filetypes()
call extend(b:context_filetype_filetypes,
      \ {'php' : [
      \   {
      \    'start':
      \     '<script\%( [^>]*\)\? type="text/javascript"\%( [^>]*\)\?>',
      \    'end': '</script>', 'filetype': 'javascript',
      \   },
      \   {
      \    'start':
      \     '<script\%( [^>]*\)\? type="text/coffeescript"\%( [^>]*\)\?>',
      \    'end': '</script>', 'filetype': 'coffee',
      \   },
      \   {
      \    'start':
      \     '<script\%( [^>]*\)\?>',
      \    'end': '</script>', 'filetype': 'javascript',
      \   },
      \   {
      \    'start':
      \     '<style\%( [^>]*\)\?>',
      \    'end': '</style>', 'filetype': 'css',
      \   },
      \   {
      \    'start':
      \     '<[^>]\+ style=\([''"]\)',
      \    'end': '\1', 'filetype': 'css',
      \   },
      \ ]})
