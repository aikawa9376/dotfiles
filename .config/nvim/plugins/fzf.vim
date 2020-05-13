" fzfからファイルにジャンプできるようにする
let g:fzf_buffers_jump = 1
nnoremap <silent> <Leader>f     m':Files<CR>
nnoremap <silent> <Leader>F     m':AllFiles<CR>
nnoremap <silent> <Leader><c-f> m':call FZFImagePreview()<CR>
nnoremap <silent> <Leader>gf    m':GFiles<CR>
nnoremap <silent> <Leader>gi    m':Gitignore<CR>
nnoremap <silent> <Leader>b     m':NavBuffers<CR>
nnoremap <silent> <Leader>a     m':Rg<CR>
nnoremap <silent> <Leader>A     m':AllRg<CR>
nnoremap <silent> <Leader>l     m':BLines<CR>
nnoremap <silent> <Leader>L     m':Lines<CR>
nnoremap <silent> <Leader>e     m':MRUFilesCWD<CR>
nnoremap <silent> <Leader>E     m':MRUFiles<CR>
nnoremap <silent> <Leader>df    :SWSqlFzfSelect<CR>
nnoremap <silent> <Leader>.     m':DotFiles<CR>
nnoremap <silent> <Leader>O     m':Outline<CR>
nnoremap <silent> <Leader>M     m':Memo<CR>
nnoremap <silent> <Leader>gc    m':BCommits<CR>
nnoremap <silent> <Leader>gC    m':Commits<CR>
nnoremap <silent> <Leader>T     :DirWordCompletions<CR>
nnoremap <silent> <Leader>tm    :TmuxSearch<CR>
nnoremap <silent> <Leader>p     :YanksAfter<CR>
nnoremap <silent> <Leader>P     :YanksBefore<CR>
nnoremap <silent> <Leader>;     :ChangeListNav<CR>
nnoremap <silent> <Leader><C-o> :JumpListNav<CR>
nnoremap <silent> <Leader>q     :Helptags<CR>
nnoremap <silent> <Leader>tt    :BTags<CR>
nnoremap <silent> <C-]>         m':call fzf#vim#tags(expand('<cword>'))<CR>
nnoremap <silent> <expr>        <Leader>] "m':Rg(" . expand("<cword>") . ")<CR>"
nnoremap <silent> q: :History:<CR>
nnoremap <silent> q/ :History/<CR>

imap <c-j>p <plug>(fzf-complete-path)
imap <c-j>l <plug>(fzf-complete-line)

nmap <Leader><tab> <plug>(fzf-maps-n)
imap j<tab> <plug>(fzf-maps-i)
xmap <Leader><tab> <plug>(fzf-maps-x)
omap <Leader><tab> <plug>(fzf-maps-o)

let g:fzf_action = {
  \ 'ctrl-t': 'tab split',
  \ 'ctrl-x': 'split',
  \ 'ctrl-v': 'vsplit' }

command! -bang -nargs=? -complete=dir Files
  \ call fzf#vim#files(<q-args>, fzf#wrap('fzf',
  \ {'options': "--ansi --no-unicode"}))
command! AllFiles call fzf#run({
  \  'source': 'fd -I --type file --follow --hidden --color=always --exclude .git',
  \  'sink': 'edit',
  \  'options': "-m -x +s --ansi --no-unicode" .
  \             ' --no-unicode --prompt=AllFiles:'.shellescape(pathshorten(getcwd())).'/',
  \  'down': '40%'})
command! -bang -nargs=* Rg
  \ call fzf#vim#grep(
  \   'rg --column --line-number --hidden --ignore-case --no-heading --color=always '.shellescape(<q-args>), 1,
  \   <bang>0 ? fzf#vim#with_preview({'options': '--delimiter : --nth 4.. --no-unicode'}, 'up:60%:wrap')
  \           : fzf#vim#with_preview({'options': '--delimiter : --nth 4.. --no-unicode'}, 'right:50%:hidden:wrap', '?'),
  \   <bang>0)
command! -bang -nargs=* AllRg
  \ call fzf#vim#grep(
  \   'rg --column --line-number --no-ignore --hidden --ignore-case --no-heading --color=always '.shellescape(<q-args>), 1,
  \   <bang>0 ? fzf#vim#with_preview({'options': '--delimiter : --nth 4.. --no-unicode'}, 'up:60%:wrap')
  \           : fzf#vim#with_preview({'options': '--delimiter : --nth 4.. --no-unicode'}, 'right:50%:hidden:wrap', '?'),
  \   <bang>0)
command! -bang -nargs=* Rgf
  \ call fzf#vim#grep(
  \   'rg --column --line-number --hidden --ignore-case --no-heading --color=always '.shellescape(<q-args>), 1,
  \   <bang>0 ? fzf#vim#with_preview({'options': '--no-unicode'}, 'up:60%:wrap')
  \           : fzf#vim#with_preview({'options': '--no-unicode'}, 'right:50%:hidden:wrap', '?'),
  \   <bang>0)
command! -bang -nargs=* Rgaf
  \ call fzf#vim#grep(
  \   'rg --column --line-number --no-ignore --hidden --ignore-case --no-heading --color=always '.shellescape(<q-args>), 1,
  \   <bang>0 ? fzf#vim#with_preview({'options': '--no-unicode'}, 'up:60%:wrap')
  \           : fzf#vim#with_preview({'options': '--no-unicode'}, 'right:50%:hidden:wrap', '?'),
  \   <bang>0)
command! -bang Lines
  \ call fzf#vim#lines({'options': '--reverse --height 40% --preview-window hidden'}, <bang>0)
command! -bang BLines
  \ call fzf#vim#buffer_lines({'options': '--reverse --height 40% --preview-window hidden'}, <bang>0)

" ------------------------------------------------------------------
" DotFiles EasySearch
" ------------------------------------------------------------------
command! DotFiles execute 'Files ~/dotfiles'

" ------------------------------------------------------------------
" Outline handling
" ------------------------------------------------------------------
function! s:outline_format(lists)
  for list in a:lists
    let linenr = list[2][:len(list[2])-3]
    let line = getline(linenr)
    let idx = stridx(line, list[0])
    let len = len(list[0])
    let list[0] = line[:idx-1] . printf("\x1b[%s%sm%s\x1b[m", 34, '', line[idx:idx+len-1]) . line[idx+len:]
  endfor
  for list in a:lists
    call map(list, "printf('%s', v:val)")
  endfor
  return a:lists
endfunction

function! s:outline_source(tag_cmds)
  if !filereadable(expand('%'))
    throw 'Save the file first'
  endif

  for cmd in a:tag_cmds
    let lines = split(system(cmd), "\n")
    if !v:shell_error
      break
    endif
  endfor
  if v:shell_error
    throw get(lines, 0, 'Failed to extract tags')
  elseif empty(lines)
    throw 'No tags found'
  endif
  return map(s:outline_format(map(lines, 'split(v:val, "\t")')), 'join(v:val, "\t")')
endfunction

function! s:outline_sink(lines)
  if !empty(a:lines)
    let line = a:lines[0]
    execute split(line, "\t")[2]
  endif
endfunction

function! s:outline(...)
  let args = copy(a:000)
  let tag_cmds = [
    \ printf('ctags -f - --sort=no --excmd=number --language-force=%s %s 2>/dev/null', &filetype, expand('%:S')),
    \ printf('ctags -f - --sort=no --excmd=number %s 2>/dev/null', expand('%:S'))]
  return {
    \ 'source':  s:outline_source(tag_cmds),
    \ 'sink*':   function('s:outline_sink'),
    \ 'options': '--reverse +m -d "\t" --with-nth 1 -n 1 --ansi --prompt "Outline> "'}
endfunction

command! -bang Outline call fzf#run(fzf#wrap('outline', s:outline(), <bang>0))

" ------------------------------------------------------------------
" MRU Navigator
" ------------------------------------------------------------------
" MRU handling, limited to current directory
command! MRUFilesCWD call fzf#run({
  \  'source': s:mru_files_for_cwd('file'),
  \  'sink*': function('<SID>mru_file_sink'),
  \  'options': '-m -x +s
  \              --no-unicode --prompt=MRU:'.shellescape(pathshorten(getcwd())).'/
  \              --expect ctrl-t --header ":: Press C-t:toggle mru or mrw" --print-query',
  \  'down': '40%'})

command! MRUWritesCWD call fzf#run({
  \  'source': s:mru_files_for_cwd('write'),
  \  'sink*': function('<SID>mrw_file_sink'),
  \  'options': '-m -x +s
  \              --no-unicode --prompt=MRU:'.shellescape(pathshorten(getcwd())).'/
  \              --expect ctrl-t --header ":: Press C-t:toggle mru or mrw" --print-query',
  \  'down': '40%'})

function! s:mru_files_for_cwd(flag)
  return map(filter(
  \  systemlist("sed -n '2,$p' $XDG_CACHE_HOME/neomru/" . a:flag),
  \  "v:val =~ '^" . getcwd() . "' && v:val !~ '__Tagbar__\\|\\[YankRing]\\|fugitive:\\|NERD_tree\\|^/tmp/\\|.git/'"
  \ ), 'fnamemodify(v:val, ":p:.")')
endfunction

command! MRUFiles call fzf#run({
  \  'source': s:mru_files_for_all('file'),
  \  'sink*': function('<SID>mru_file_all_sink'),
  \  'options': '-m -x +s
  \              --no-unicode --prompt=MRU_ALL:'.shellescape(pathshorten(getcwd())).'/
  \              --expect ctrl-t --header ":: Press C-t:toggle mru or mrw" --print-query',
  \  'down': '40%'})

command! MRUWrites call fzf#run({
  \  'source': s:mru_files_for_all('write'),
  \  'sink*': function('<SID>mrw_file_all_sink'),
  \  'options': '-m -x +s
  \              --no-unicode --prompt=MRU_ALL:'.shellescape(pathshorten(getcwd())).'/
  \              --expect ctrl-t --header ":: Press C-t:toggle mru or mrw" --print-query',
  \  'down': '40%'})

function! s:mru_files_for_all(flag)
  return map(filter(
  \  systemlist("sed -n '2,$p' $XDG_CACHE_HOME/neomru/" . a:flag),
  \  "v:val !~ '__Tagbar__\\|\\[YankRing]\\|fugitive:\\|NERD_tree\\|^/tmp/\\|.git/'"
  \ ), 'fnamemodify(v:val, ":p:.")')
endfunction

" refactoring
function! s:mru_file_sink(lines)
  if len(a:lines) < 3
    return
  endif
  let s:dir = FindRootDirectory()
  if a:lines[1] == ''
    for w in range(2, len(a:lines) - 1)
      execute("edit " . a:lines[w])
    endfor
    return
  elseif a:lines[1] == 'ctrl-t'
    execute('MRUWritesCWD ' . a:lines[0])
    call feedkeys(":start\<CR>")
    return
  endif
endfunction
function! s:mrw_file_sink(lines)
  if len(a:lines) < 3
    return
  endif
  let s:dir = FindRootDirectory()
  if a:lines[1] == ''
    for w in range(2, len(a:lines) - 1)
      execute("edit " . a:lines[w])
    endfor
    return
  elseif a:lines[1] == 'ctrl-t'
    execute('MRUFilesCWD ' . a:lines[0])
    call feedkeys(":start\<CR>")
    return
  endif
endfunction
function! s:mru_file_all_sink(lines)
  if len(a:lines) < 3
    return
  endif
  let s:dir = FindRootDirectory()
  if a:lines[1] == ''
    for w in range(2, len(a:lines) - 1)
      execute("edit " . a:lines[w])
    endfor
    return
  elseif a:lines[1] == 'ctrl-t'
    execute('MRUWrites ' . a:lines[0])
    call feedkeys(":start\<CR>")
    return
  endif
endfunction
function! s:mrw_file_all_sink(lines)
  if len(a:lines) < 3
    return
  endif
  let s:dir = FindRootDirectory()
  if a:lines[1] == ''
    for w in range(2, len(a:lines) - 1)
      execute("edit " . a:lines[w])
    endfor
    return
  elseif a:lines[1] == 'ctrl-t'
    execute('MRUFiles ' . a:lines[0])
    call feedkeys(":start\<CR>")
    return
  endif
endfunction

" ------------------------------------------------------------------
" TmuxPane complete
" ------------------------------------------------------------------
command! -bang TmuxSearch call fzf#run(fzf#wrap('tmux', {
    \ 'source':tmuxcomplete#list('words', 0),
    \ 'sink*':function('<SID>fzf_insert_at_point'),
    \ 'options': '--reverse +m -d "\t" --with-nth 1 -n 1 --ansi --prompt "Tmux> "'}, <bang>0))

function! s:fzf_insert_at_point(s) abort
  execute "put ='".a:s[0]."'"
endfunction

" use deoplete not need map
" inoremap <expr> <C-l> fzf#complete({'source': tmuxcomplete#list('lines', 0)})
" inoremap <expr> <M-w> fzf#complete({'source': tmuxcomplete#list('words', 0)})

" ------------------------------------------------------------------
" DirectoryWords Selector
" ------------------------------------------------------------------
function! s:fzf_last_word() abort
  " insert 2 normal 1
  let prev_pos = col('.') - 2
  let before_str = getline('.')[0:prev_pos]
  let last_word = matchstr(before_str, '\m\(\k\+\)$')
  return last_word
endfunction

" working dir word completions
command! -nargs=* DirWordCompletions call fzf#run({
  \  'source': s:dir_word_completion(s:fzf_last_word()),
  \  'sink': 'edit',
  \  'options': '-m -x +s --ansi --prompt=DirWords:'.shellescape(s:fzf_last_word()),
  \  'down': '40%'})

function! s:dir_word_completion(word)
  return  systemlist("rg --hidden -w -o '" . a:word . "[A-Za-z0-9-_]+' | sed -e 's/^.*://g' | sort | uniq")
endfunction

imap <expr> <C-t> fzf#complete({
    \ 'source': <SID>dir_word_completion(<SID>fzf_last_word()),
    \ 'window': 'call OpenFloatingWin()',
    \ 'options': '-m -x +s --layout='.shellescape(<SID>open_floatingWin_fzf_layout())})

" ------------------------------------------------------------------
" Directory And FileName Selector
" ------------------------------------------------------------------
imap <expr> <C-_> fzf#complete({
    \ 'source': <SID>dir_file_completion(<SID>fzf_last_word()),
    \ 'reducer': function('<SID>dir_file_sink'),
    \ 'window': 'call OpenFloatingWin()',
    \ 'options': '-m -x +s --ansi --print-query --layout='.shellescape(<SID>open_floatingWin_fzf_layout())})

function! s:dir_file_completion(word)
  " return  systemlist("fd --follow --hidden --color=always --exclude .git '^" . a:word . "' | tr '/' '\n' | sort | uniq")
  return  systemlist("fd --follow --hidden --color=always --exclude .git '^" . a:word . "' | sort | uniq")
endfunction

function! s:dir_file_sink(lines)
  echomsg string(a:lines)
  let rmpath = substitute(a:lines[1],'.\+'.a:lines[0],a:lines[0],'g')
  return rmpath
endfunction

" ------------------------------------------------------------------
" JunkFile Navigator
" ------------------------------------------------------------------
command! -nargs=* Memo call fzf#run({
  \  'source': s:junk_file_list(),
  \  'sink*': function('<SID>junk_file_sink'),
  \  'options': '-m -x +s --ansi --preview-window hidden --prompt=Memo:'.shellescape(<q-args>),
  \  'down': '40%'})

function! s:junk_file_list()
  let workdir = s:get_root_dir_for_junk()
  return  systemlist("
  \  rg --column -n --hidden --ignore-case --color=always '' $XDG_CACHE_HOME/junkfile/".workdir."/ |
  \  sed -e 's%'$XDG_CACHE_HOME'/junkfile/".workdir."/%%g'
  \  ")
endfunction

function! s:get_root_dir_for_junk()
  " depends vim rooter
  if exists('*FindRootDirectory') && FindRootDirectory() != ''
    let s:dir = FindRootDirectory()
    let s:dir = split(s:dir, '/')
    return s:dir[len(s:dir) - 1]
  else
    return ''
  endif
endfunction

function! s:junk_file_sink(line) abort
  execute "edit +" . split(a:line[0], ':')[1] . " ~/.cache/junkfile/" . split(a:line[0], ':')[0]
endfunction

" ------------------------------------------------------------------
" Git Navigator
" ------------------------------------------------------------------
command! -nargs=* Gitignore call fzf#run({
  \  'source': s:ignore_file_list(),
  \  'sink*': function('<SID>ignore_file_sink'),
  \  'options': '--prompt=Gitignore: --query '.shellescape(<q-args>) . ' -m -x +s  ' .
  \  '--header ":: Press C-x:delete ignore lines C-t:toggle C-m:comment toggle" --print-query ' .
  \  '--ansi --expect ctrl-x,ctrl-m,ctrl-t',
  \  'down': '40%'})

function! s:ignore_file_list()
  " depends vim rooter
  if exists('*FindRootDirectory') && FindRootDirectory() != ''
    let s:dir = FindRootDirectory()
    return  systemlist("rg --column -n --hidden --ignore-case --color=always '' " . s:dir . "/.gitignore")
  else
    return 'no git repository'
  endif
endfunction

function! s:ignore_file_sink(lines)
  if len(a:lines) < 3
    return
  endif
  let s:dir = FindRootDirectory()
  if a:lines[1] == ''
    let no= split(a:lines[2], ':')[0]
    execute("silent !sed -i -e '" . no . "d' " . s:dir . "/.gitignore &")
    return
  elseif a:lines[1] == 'ctrl-x'
    for w in range(2, len(a:lines) - 1)
      let no= split(a:lines[w], ':')[0]
      execute("silent !sed -i -e '" . no . "d' " . s:dir . "/.gitignore &")
    endfor
  elseif a:lines[1] == 'ctrl-m'
    for w in range(2, len(a:lines) - 1)
      let no= split(a:lines[w], ':')[0]
      let name = split(a:lines[w], ':')[2]
      if name[0] == "#"
        execute('silent !sed -i -e "' . no . 's/^\\#//" ' . s:dir . '/.gitignore &')
      else
        execute('silent !sed -i -e "' . no . 's/^/\\#/" ' . s:dir . '/.gitignore &')
      endif
    endfor
  elseif a:lines[1] == 'ctrl-t'
    execute('AddGitignore')
    call feedkeys(":start\<CR>")
    return
  endif
  " execute("Gina add " . fnamemodify(a:lines[0], ":p"))
  execute('Gitignore ' . a:lines[0])
  call feedkeys(":start\<CR>")
  return
endfunction

command! -nargs=* AddGitignore call fzf#run({
  \  'source': <SID>dir_file_completion(''),
  \  'sink*': function('<SID>add_ignore_file_sink'),
  \  'options': '--prompt=AllGitignore: --query '.shellescape(<q-args>) . ' -m -x +s  ' .
  \  '--header ":: Press C-x:add ignore lines C-t:toggle" --print-query ' .
  \  '--ansi --expect ctrl-x,ctrl-t',
  \  'down': '40%'})

function! s:add_ignore_file_sink(lines) abort
  if len(a:lines) < 3
    return
  endif
  if exists('*FindRootDirectory') && FindRootDirectory() != ''
    let s:dir = FindRootDirectory()
  else
    return 'no git repository'
  endif

  if a:lines[1] == 'ctrl-x'
    for w in range(2, len(a:lines) - 1)
      let t = a:lines[w]
      execute("silent !echo " . t . " >> " . s:dir . "/.gitignore")
      execute("Gina rm --cached " . fnamemodify(t, ":p"))
    endfor
    execute('AddGitignore ' . a:lines[0])
    call feedkeys(":start\<CR>")
    return
  elseif a:lines[1] == 'ctrl-t'
    execute('Gitignore')
    call feedkeys(":start\<CR>")
    return
  endif
  execute("Gina rm --cached " . fnamemodify(a:lines[2], ":p"))
  execute("silent !echo " . a:lines[2] . " >> " . s:dir . "/.gitignore")
endfunction

function s:override_gitfiles_sink(lines) abort
  if len(a:lines) < 2
    return
  endif
  if exists('*FindRootDirectory') && FindRootDirectory() != ''
    let s:dir = FindRootDirectory()
  else
    return 'no git repository'
  endif
  if a:lines[0] == 'ctrl-x'
    for w in range(1, len(a:lines) - 1)
      execute("Gina rm --cached " . a:lines[w])
    endfor
    execute('GFiles')
    call feedkeys(":start\<CR>")
    return
  endif
  for w in range(1, len(a:lines) - 1)
    execute("edit ". fnamemodify(a:lines[w], ":p"))
  endfor
endfunction

command! -bang -nargs=? -complete=dir GFiles
  \ call fzf#vim#gitfiles(<q-args>, fzf#wrap('fzf',
  \ {'sink*': function('<SID>override_gitfiles_sink'),
  \  'options': "-m -x +s --no-unicode
  \  --header \":: Press C-x:rm cached\"
  \  --expect ctrl-x"}))

" ------------------------------------------------------------------
" YankRing fzf
" ------------------------------------------------------------------
function! FZFYankList() abort
  function! KeyValue(key, val)
    let line = join(a:val[0], '⏎')
    if (a:val[1] ==# 'V')
      let line = '⏎'.line
    endif
    return a:key.' '.line
  endfunction
  return map(miniyank#read(), function('KeyValue'))
endfunction

function! FZFYankHandler(opt, line) abort
  let key = substitute(a:line, ' .*', '', '')
  if !empty(a:line)
    let yanks = miniyank#read()[key]
    call miniyank#drop(yanks, a:opt)
  endif
endfunction

command! YanksAfter call fzf#run(fzf#wrap('YanksAfter', {
\ 'source':  FZFYankList(),
\ 'sink':    function('FZFYankHandler', ['p']),
\ 'options': '--no-sort --prompt="Yanks-p> "',
\ }))

command! YanksBefore call fzf#run(fzf#wrap('YanksBefore', {
\ 'source':  FZFYankList(),
\ 'sink':    function('FZFYankHandler', ['P']),
\ 'options': '--no-sort --prompt="Yanks-P> "',
\ }))

" ------------------------------------------------------------------
" Buffer Navigator
" ------------------------------------------------------------------
function! s:bufopen(lines)
  if len(a:lines) < 3
    return
  endif

  if a:lines[1] == 'ctrl-k'
    execute('bwipeout')
    execute('NavBuffers ' . a:lines[0])
    call feedkeys(":start\<CR>")
    return
  endif

  if a:lines[1] == 'ctrl-d'
    for w in range(2, len(a:lines) - 1)
      let b = a:lines[w]
      let index = matchstr(b, '^\[\([0-9a-f]\+\)\]')
      execute('bwipeout ' . index[1:len(index)-2])
    endfor
    execute('NavBuffers ' . a:lines[0])
    call feedkeys(":start\<CR>")
    return
  endif

  if a:lines[1] == 'ctrl-b'
    let index = matchstr(a:lines[2], '\[\zs[0-9]*\ze\]')
    execute 'buffer ' index
    execute('NavBuffers ' . a:lines[0])
    call feedkeys(":start\<CR>")
    return
  endif

  let b = matchstr(a:lines[2], '\[\zs[0-9]*\ze\]')
  let cmd = get(g:fzf_action, a:lines[1])
  if !empty(cmd)
    execute 'silent ' cmd
    execute 'buffer ' b
    execute('NavBuffers ' . a:lines[0])
    call feedkeys(":start\<CR>")
    return
  endif
  execute 'buffer ' b
endfunction

function! s:strip(str)
  return substitute(a:str, '^\s*\|\s*$', '', 'g')
endfunction

function! s:buflisted()
  return filter(range(1, bufnr('$')), 'buflisted(v:val) && getbufvar(v:val, "&filetype") != "qf"')
endfunction

function! s:format_buffer(b)
  let name = bufname(a:b)
  let name = empty(name) ? '[No Name]' : fnamemodify(name, ":p:~:.")
  let flag = a:b == bufnr('')  ? '%' :
          \ (a:b == bufnr('#') ? '#' : ' ')
  let modified = getbufvar(a:b, '&modified') ? ' [+]' : ''
  let readonly = getbufvar(a:b, '&modifiable') ? '' : ' [RO]'
  let extra = join(filter([modified, readonly], '!empty(v:val)'), '')
  if flag == '%'
    return s:strip(printf("\033[38;2;102;204;0m[%s] %s - %s %s %s\033[0m", a:b, fnamemodify(name, ':t'), fnamemodify(name, ':h') . '/' , flag, extra))
  elseif flag == '#'
    return s:strip(printf("\033[38;2;51;153;255m[%s] %s - %s %s %s\033[0m", a:b, fnamemodify(name, ':t'), fnamemodify(name, ':h') . '/', flag, extra))
  else
    return s:strip(printf("[%s] %s - %s %s %s", a:b, fnamemodify(name, ':t'), fnamemodify(name, ':h') . '/', flag, extra))
  endif
endfunction

function! s:sort_buffers(...)
  return copy(a:000)
endfunction

command! -nargs=* NavBuffers
  \ call fzf#run(fzf#wrap('navbuffers', {
  \ 'source':  map(s:buflisted(), 's:format_buffer(v:val)'),
  \ 'sink*':   function('<SID>bufopen'),
  \ 'window': 'call OpenFloatingWinCenter()',
  \ 'options': [
  \   '-m', '-x', '--tiebreak=index', '--ansi', '-d',
  \   '\t', '-n', '2,1..2', '--prompt', 'Buf> ', '--query', <q-args>,
  \   '--header', ':: Press C-D Del C-b Preview And Default Key Working',
  \   '--preview-window', 'hidden',
  \   '--print-query', '--expect=ctrl-d,ctrl-b,ctrl-x,ctrl-v,ctrl-k', '--no-unicode'],
  \   'up': '30%',
  \ }))

" ------------------------------------------------------------------
" ChangeList Navigator
" ------------------------------------------------------------------
function! s:getChenges()
  let listtext = execute("changes")
  let list = reverse(split(listtext, "\n"))
  call remove(list, 0)
  call remove(list, len(list) - 1)
  return list
endfunction

function! s:cursorMove(line)
  let linelist = substitute(a:line[0],'\s\+',",","g")
  execute "call cursor(" . split(linelist, ',')[1] . "," . split(linelist, ',')[2] . ")"
endfunction

command! -nargs=* ChangeListNav call fzf#run({
  \  'source': s:getChenges(),
  \  'sink*':   function('<SID>cursorMove'),
  \  'options': '--reverse -m -x +s --ansi --prompt=ChangeList:',
  \  'down': '40%'})

" ------------------------------------------------------------------
" JumpList Navigator
" ------------------------------------------------------------------
function! s:getjumps()
  let listtext = execute("jumps")
  let list = reverse(split(listtext, "\n"))
  call remove(list, 0)
  call remove(list, len(list) - 1)
  return list
endfunction

function! s:cursorMove(line)
  let linelist = substitute(a:line[0],'\s\+',",","g")
  if filereadable(fnamemodify(split(linelist, ',')[3], ':p'))
    execute "e " . fnamemodify(split(linelist, ',')[3], ':p')
    execute "call cursor(" . split(linelist, ',')[1] . "," . split(linelist, ',')[2] . ")"
  else
    execute "call cursor(" . split(linelist, ',')[1] . "," . split(linelist, ',')[2] . ")"
  endif
endfunction

command! -nargs=* JumpListNav call fzf#run({
  \  'source': s:getjumps(),
  \  'sink*':   function('<SID>cursorMove'),
  \  'options': '--reverse -m -x +s --ansi --prompt=JumpList:',
  \  'down': '40%'})

" ------------------------------------------------------------------
" ColorScheme Viewer
" ------------------------------------------------------------------
function! s:gethighlight()
  let listtext = execute("highlight")
  let list = split(listtext, "\n")
  return list
endfunction

command! -nargs=* HighLight call fzf#run({
  \  'source': s:gethighlight(),
  \  'options': '--reverse -m -x +s --ansi --prompt=Highlight:',
  \  'down': '40%'})

" ------------------------------------------------------------------
" PHP Refactor Menu
" ------------------------------------------------------------------
function! s:getphprefmenu()
  let menus = {
      \ "Rename Local Variable" : "call PhpRenameLocalVariable()" ,
      \ "Rename Class Variable" : "call PhpRenameClassVariable()" ,
      \ "Rename Method" : "call PhpRenameMethod()" ,
      \ "Extract Use" : "call PhpExtractUse()" ,
      \ "Extract Const" : "call PhpExtractConst()" ,
      \ "Extract Class Property" : "call PhpExtractClassProperty()" ,
      \ "Extract Method" : "call PhpExtractMethod()" ,
      \ "Create Property" : "call PhpCreateProperty()" ,
      \ "Detect Unused Use Statements" : "call PhpDetectUnusedUseStatements()" ,
      \ "Align Assigns" : "call PhpAlignAssigns()" ,
      \ "Create setters and getters" : "call PhpCreateGetters()" ,
      \ "Document all code" : "call PhpDocAll()" }
  return menus
endfunction

function! s:getphprefsink(lines) abort
  let menus = <SID>getphprefmenu()
  execute menus[a:lines[0]]
endfunction
command! -nargs=* PhpRefactorringMenu call fzf#run({
  \  'source': sort(keys(s:getphprefmenu())),
  \  'sink*':   function('<SID>getphprefsink'),
  \  'options': '--reverse -m -x +s --ansi --prompt=PhpRefactorMenu:',
  \  'down': '20%'})

" ------------------------------------------------------------------
" QuickFix
" ------------------------------------------------------------------
command! Fq FZFQuickfix
command! FZFQuickfix call fzf#run({
  \  'source':  Get_qf_text_list(),
  \  'sink':    function('s:qf_sink'),
  \  'options': '-m -x +s',
  \  'down':    '40%'})

" QuickFix形式にqfListから文字列を生成する
function! Get_qf_text_list()
  let qflist = getqflist()
  let textList = []
  for i in qflist
    if i.valid
      let textList = add(textList, printf('%s|%d| %s',
        \  bufname(i.bufnr),
        \  i.lnum,
        \  matchstr(i.text, '\s*\zs.*\S')
        \  ))
    endif
  endfor
  return textList
endfunction

" QuickFix形式のstringからtabeに渡す
function! s:qf_sink(line)
    let parts = split(a:line, '\s')
    execute 'tabe ' . parts[0]
endfunction

" ------------------------------------------------------------------
" Image Preview
" ------------------------------------------------------------------
function! FZFImagePreview()
  call OpenFloatingWinFull()
  call termopen('~/dotfiles/.config/zsh/ueberzogen/fzf-vim-preview.sh -m --height=100%',
    \ {'on_exit': function('<SID>on_exit')})

  startinsert

  setlocal
    \ nobuflisted
    \ bufhidden=hide
    \ nonumber
    \ norelativenumber
    \ signcolumn=no
endfunction

fun! s:on_exit(job_id, code, event) dict
    if a:code == 0
      let list = []
      let count = 1
      while getline(count) != ''
        call add(list, getline(count))
        let count += 1
      endwhile
      close
      call s:callback('e', list)
    endif
endfun

fun! s:callback(func, lines) abort
  for item in a:lines
    exe(a:func . " " . item)
  endfor
endfun

" ------------------------------------------------------------------
" Floating window
" ------------------------------------------------------------------
function! OpenFloatingWinCenter()
  let height = float2nr(&lines / 2)
  let width  = float2nr(&columns * 0.6)
  let row    = float2nr((&lines - height) / 2)
  let col    = float2nr((&columns - width) / 2)

  let opts = {
    \ 'relative': 'editor',
    \ 'row': row,
    \ 'col': col,
    \ 'width': width,
    \ 'height': height
    \ }

  let buf = nvim_create_buf(v:false, v:true)
  let win = nvim_open_win(buf, v:true, opts)

  call setwinvar(win, '&winhl', 'Normal:Fmenu')
  IndentLinesToggle

  setlocal
    \ buftype=nofile
    \ nobuflisted
    \ bufhidden=hide
    \ nonumber
    \ norelativenumber
    \ signcolumn=no
endfunction

function! OpenFloatingWinFull()
  let height = &lines
  let width = &columns

  let opts = {
    \ 'relative': 'editor',
    \ 'col': float2nr(width * 0.05),
    \ 'row': float2nr(height * 0.05),
    \ 'width': float2nr(width * 0.9),
    \ 'height': float2nr(height * 0.9)
    \ }

  let buf = nvim_create_buf(v:false, v:true)
  let win = nvim_open_win(buf, v:true, opts)

  call setwinvar(win, '&winhl', 'Normal:Fmenu')
  IndentLinesToggle

  setlocal
    \ buftype=nofile
    \ nobuflisted
    \ bufhidden=hide
    \ nonumber
    \ norelativenumber
    \ signcolumn=no
endfunction

function! OpenFloatingWin()
  let height = 20
  let width = float2nr(&columns - (&columns * 2 / 10))
  let width = float2nr(width * 2 / 3)
  let opened_at = getpos('.')

  let bottom_line = line('w0') + winheight(0) - 1
  if opened_at[1] + height <= bottom_line
    let vert = 'N'
    let row = 1
  else
    let vert = 'S'
    let row = 0
  endif

  if opened_at[2] + width <= &columns
    let hor = 'W'
    let col = 0
  else
    let hor = 'E'
    let col = 1
  endif

  let opts = {
    \ 'relative': 'cursor',
    \ 'anchor': vert . hor,
    \ 'row': row,
    \ 'col': col,
    \ 'width': width,
    \ 'height': height,
    \ }

  let buf = nvim_create_buf(v:false, v:true)
  let win = nvim_open_win(buf, v:true, opts)

  call setwinvar(win, '&winhl', 'Normal:Fmenu')
  IndentLinesToggle

  setlocal
    \ buftype=nofile
    \ nobuflisted
    \ bufhidden=hide
    \ nonumber
    \ norelativenumber
    \ signcolumn=no
endfunction

function! s:open_floatingWin_fzf_layout() abort
  let height = 20
  let width = float2nr(&columns - (&columns * 2 / 10))
  let width = float2nr(width * 2 / 3)
  let opened_at = getpos('.')

  let bottom_line = line('w0') + winheight(0) - 1
  if opened_at[1] + height <= bottom_line
    let layout = 'reverse'
  else
    let layout = 'default'
  endif
  return layout
endfunction
