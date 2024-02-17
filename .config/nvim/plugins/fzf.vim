" fzfからファイルにジャンプできるようにする
let g:fzf_buffers_jump = 1
nnoremap <silent> <Leader>f     m`<cmd>Files<CR>
nnoremap <silent> <Leader>F     m`<cmd>AllFiles<CR>
nnoremap <silent> <Leader><c-f> m`<cmd>call FZFImagePreview()<CR>
nnoremap <silent> <Leader>gf    m`<cmd>GFiles<CR>
nnoremap <silent> <Leader>gi    m`<cmd>Gitignore<CR>
nnoremap <silent> <Leader>b     m`<cmd>NavBuffers<CR>
nnoremap <silent> <Leader>a     m`<cmd>Rg<CR>
nnoremap <silent> <Leader>A     m`<cmd>AllRg<CR>
nnoremap <silent> <Leader>l     m`<cmd>BLines<CR>
nnoremap <silent> <Leader>L     m`<cmd>Lines<CR>
nnoremap <silent> <Leader>e     m`<cmd>MRUFilesCWD<CR>
nnoremap <silent> <Leader>E     m`<cmd>MRUFiles<CR>
nnoremap <silent> <Leader>df    <cmd>SWSqlFzfSelect<CR>
nnoremap <silent> <Leader>.     m`<cmd>DotFiles<CR>
nnoremap <silent> <Leader>O     m`<cmd>OutLine<CR>
nnoremap <silent> <Leader>M     m`<cmd>Memo<CR>
nnoremap <silent> <Leader>gc    m`<cmd>BCommits<CR>
nnoremap <silent> <Leader>gC    m`<cmd>Commits<CR>
nnoremap <silent> <Leader>T     <cmd>DirWordCompletions<CR>
nnoremap <silent> <Leader>tm    <cmd>TmuxSearch<CR>
nnoremap <silent> <Leader>p     <cmd>YanksAfter<CR>
nnoremap <silent> <Leader>P     <cmd>YanksBefore<CR>
nnoremap <silent> <Leader>;     <cmd>ChangeListNav<CR>
nnoremap <silent> <Leader><C-o> <cmd>JumpListNav<CR>
nnoremap <silent> <Leader>q     <cmd>Helptags<CR>
nnoremap <silent> <Leader>tt    <cmd>BTags<CR>
nnoremap <silent> <C-]>         m'<cmd>call fzf#vim#tags(expand('<cword>'))<CR>
nnoremap <silent> <expr>        <Leader>] "m'<cmd>Rg(" . expand("<cword>") . ")<CR>"
nnoremap <silent> q: <cmd>History:<CR>
nnoremap <silent> q/ <cmd>History/<CR>
nnoremap <silent> s<Space>      m`<cmd>NavBuffers<CR>

imap <c-j>p <plug>(fzf-complete-path)
imap <c-j>l <plug>(fzf-complete-line)

nmap <Leader><tab> <plug>(fzf-maps-n)
imap j<tab> <plug>(fzf-maps-i)
xmap <Leader><tab> <plug>(fzf-maps-x)
omap <Leader><tab> <plug>(fzf-maps-o)

let g:fzf_layout = { 'down': '40%' }

let g:fzf_action = {
  \ 'ctrl-t': 'tab split',
  \ 'ctrl-x': 'split',
  \ 'ctrl-v': 'vsplit' }

let g:fzf_colors = {
  \ 'fg+': ['fg', 'CursorLine', 'CursorColumn', 'Normal'],
  \ 'bg+': ['bg', 'Normal', 'CursorLine'],
  \ }

command! -bang -nargs=* Rg
  \ call fzf#vim#grep(
  \   'rg --column --line-number --hidden --ignore-case --no-heading --color=always --glob=!.git '.shellescape(<q-args>), 1,
  \   <bang>0 ? fzf#vim#with_preview({'options': '--delimiter : --nth 4..,1 --no-unicode'}, 'up:60%:wrap')
  \           : fzf#vim#with_preview({'options': '--delimiter : --nth 4..,1 --no-unicode'}, 'right:50%:hidden:wrap', '?'),
  \   <bang>0)
command! -bang -nargs=* AllRg
  \ call fzf#vim#grep(
  \   'rg --column --line-number --no-ignore --hidden --ignore-case --no-heading --color=always --glob=!.git '.shellescape(<q-args>), 1,
  \   <bang>0 ? fzf#vim#with_preview({'options': '--delimiter : --nth 4.. --no-unicode'}, 'up:60%:wrap')
  \           : fzf#vim#with_preview({'options': '--delimiter : --nth 4.. --no-unicode'}, 'right:50%:hidden:wrap', '?'),
  \   <bang>0)
command! -bang -nargs=* Rgf
  \ call fzf#vim#grep(
  \   'rg --column --line-number --hidden --ignore-case --no-heading --color=always --glob=!.git '.shellescape(<q-args>), 1,
  \   <bang>0 ? fzf#vim#with_preview({'options': '--no-unicode'}, 'up:60%:wrap')
  \           : fzf#vim#with_preview({'options': '--no-unicode'}, 'right:50%:hidden:wrap', '?'),
  \   <bang>0)
command! -bang -nargs=* Rgaf
  \ call fzf#vim#grep(
  \   'rg --column --line-number --no-ignore --hidden --ignore-case --no-heading --color=always --glob=!.git '.shellescape(<q-args>), 1,
  \   <bang>0 ? fzf#vim#with_preview({'options': '--no-unicode'}, 'up:60%:wrap')
  \           : fzf#vim#with_preview({'options': '--no-unicode'}, 'right:50%:hidden:wrap', '?'),
  \   <bang>0)
command! -bang Lines
  \ call fzf#vim#lines({'options': '--reverse --height 40% --preview-window hidden'}, <bang>0)
command! -bang BLines
  \ call fzf#vim#buffer_lines({'options': '--reverse --height 40% --preview-window hidden'}, <bang>0)

" ------------------------------------------------------------------
" Files Enhanced
" ------------------------------------------------------------------
function s:override_files_sink(lines) abort
  if len(a:lines) < 2
    return
  endif
  if a:lines[0] == 'ctrl-x'
    for w in range(1, len(a:lines) - 1)
      execute("silent !rm " . a:lines[w])
    endfor
    call feedkeys("\<cmd>Files\<CR>")
    return
  endif
  if a:lines[0] == 'ctrl-v'
    for w in range(1, len(a:lines) - 1)
      execute("vsplit " . a:lines[w])
    endfor
  endif
  if a:lines[0] == 'ctrl-q'
    call remove(a:lines, 0)
    call setqflist(map(copy(a:lines), '{ "filename": v:val }'))
    copen
    cc
  endif
  for w in range(1, len(a:lines) - 1)
    execute("edit ". fnamemodify(a:lines[w], ":p"))
  endfor
endfunction

command! -bang -nargs=? -complete=dir Files
  \ call fzf#vim#files(<q-args>, fzf#wrap('fzf',
  \ {'sink*': function('<SID>override_files_sink'),
  \  'source': 'fd --strip-cwd-prefix --follow --hidden --exclude .git --type f --print0 . ' .
  \            '-E .git -E ''*.psd'' -E ''*.png'' -E ''*.jpg'' -E ''*.pdf'' ' .
  \            '-E ''*.ai'' -E ''*.jfif'' -E ''*.jpeg'' -E ''*.gif'' ' .
  \            '-E ''*.eps'' -E ''*.svg'' -E ''*.JPEG'' -E ''*.mp4'' ' .
  \            '| xargs -0 eza -1 -sold --color=always --no-quotes',
  \  'options': '--ansi -m -x --no-unicode --scheme=history '.
  \             '--expect ctrl-x,ctrl-v,ctrl-q'}))

command! AllFiles call fzf#run({
  \  'source': 'fd --strip-cwd-prefix -I --type file --follow --hidden --color=always --exclude .git',
  \  'sink': 'edit',
  \  'options': "-m -x --ansi --no-unicode --scheme=history" .
  \             ' --no-unicode --prompt=AllFiles:'.shellescape(pathshorten(getcwd())).'/',
  \  'down': '40%'})
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

command! -bang OutLine call fzf#run(fzf#wrap('outline', s:outline(), <bang>0))

" ------------------------------------------------------------------
" MRU Navigator
" ------------------------------------------------------------------
" MRU handling, limited to current directory
command! MRUFilesCWD call fzf#run({
  \  'source': s:mru_files_for_cwd('file'),
  \  'sink*': function('<SID>mru_file_sink'),
  \  'options': '-m -x --ansi --scheme=history
  \              --no-unicode --prompt=MRU:'.shellescape(pathshorten(getcwd())).'/
  \              --expect ctrl-t --header ":: Press C-t:toggle mru or mrw" --print-query',
  \  'down': '40%'})

command! MRUWritesCWD call fzf#run({
  \  'source': s:mru_files_for_cwd('write'),
  \  'sink*': function('<SID>mrw_file_sink'),
  \  'options': '-m -x --ansi --scheme=history
  \              --no-unicode --prompt=MRW:'.shellescape(pathshorten(getcwd())).'/
  \              --expect ctrl-t --header ":: Press C-t:toggle mru or mrw" --print-query',
  \  'down': '40%'})

function! s:mru_files_for_cwd(flag)
  return s:color_filename(map(filter(
  \  systemlist("sed -n '2,$p' $XDG_CACHE_HOME/neomru/" . a:flag),
  \  "v:val =~ '^" . getcwd() . "' && v:val !~ '__Tagbar__\\|\\[YankRing]\\|fugitive:\\|NERD_tree\\|^/tmp/\\|.git/'"
  \ ), 'fnamemodify(v:val, ":p:.")'))
endfunction

command! MRUFiles call fzf#run({
  \  'source': s:mru_files_for_all('file'),
  \  'sink*': function('<SID>mru_file_all_sink'),
  \  'options': '-m -x --ansi --scheme=history
  \              --no-unicode --prompt=MRU_ALL:'.shellescape(pathshorten(getcwd())).'/
  \              --expect ctrl-t --header ":: Press C-t:toggle mru or mrw" --print-query',
  \  'down': '40%'})

command! MRUWrites call fzf#run({
  \  'source': s:mru_files_for_all('write'),
  \  'sink*': function('<SID>mrw_file_all_sink'),
  \  'options': '-m -x --ansi --scheme=history
  \              --no-unicode --prompt=MRW_ALL:'.shellescape(pathshorten(getcwd())).'/
  \              --expect ctrl-t --header ":: Press C-t:toggle mru or mrw" --print-query',
  \  'down': '40%'})

function! s:mru_files_for_all(flag)
  return s:color_filename(map(filter(
  \  systemlist("sed -n '2,$p' $XDG_CACHE_HOME/neomru/" . a:flag),
  \  "v:val !~ '__Tagbar__\\|\\[YankRing]\\|fugitive:\\|NERD_tree\\|^/tmp/\\|.git/'"
  \ ), 'fnamemodify(v:val, ":p:.")'))
endfunction

" refactoring
function! s:mru_file_sink(lines)
  if len(a:lines) < 3
    return
  endif
  if a:lines[1] == ''
    for w in range(2, len(a:lines) - 1)
      execute("edit " . a:lines[w])
    endfor
    return
  elseif a:lines[1] == 'ctrl-t'
    call feedkeys("\<cmd>MRUWritesCWD " . a:lines[0] . "\<CR>")
    return
  endif
endfunction
function! s:mrw_file_sink(lines)
  if len(a:lines) < 3
    return
  endif
  if a:lines[1] == ''
    for w in range(2, len(a:lines) - 1)
      execute("edit " . a:lines[w])
    endfor
    return
  elseif a:lines[1] == 'ctrl-t'
    call feedkeys("\<cmd>MRUFilesCWD " . a:lines[0] . "\<CR>")
    return
  endif
endfunction
function! s:mru_file_all_sink(lines)
  if len(a:lines) < 3
    return
  endif
  if a:lines[1] == ''
    for w in range(2, len(a:lines) - 1)
      execute("edit " . a:lines[w])
    endfor
    return
  elseif a:lines[1] == 'ctrl-t'
    call feedkeys("\<cmd>MRUWrites " . a:lines[0] . "\<CR>")
    return
  endif
endfunction
function! s:mrw_file_all_sink(lines)
  if len(a:lines) < 3
    return
  endif
  if a:lines[1] == ''
    for w in range(2, len(a:lines) - 1)
      execute("edit " . a:lines[w])
    endfor
    return
  elseif a:lines[1] == 'ctrl-t'
    call feedkeys("\<cmd>MRUFiles " . a:lines[0] . "\<CR>")
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
  \  'options': '-m -x --ansi --prompt=DirWords:'.shellescape(s:fzf_last_word()),
  \  'down': '40%'})

function! s:dir_word_completion(word)
  return  systemlist("rg --hidden -w -o '" . a:word . "[A-Za-z0-9-_]+' | sed -e 's/^.*://g' | awk '{ v[$0]++ } END { for ( k in v ) print k }' | sort")
  " return  systemlist("rg --hidden -w -o '" . a:word . "[A-Za-z0-9-_]+' | sed -e 's/^.*://g' | awk '{ v[$0]++ } END { for ( k in v ) print k }'")
  " return  systemlist("rg --hidden -w -o '" . a:word . "[A-Za-z0-9-_]+' | sed -e 's/^.*://g' | sort | uniq")
endfunction

imap <expr> <C-t> fzf#complete({
    \ 'source': <SID>dir_word_completion(<SID>fzf_last_word()),
    \ 'window': 'call OpenFloatingWin()',
    \ 'options': '-m -x --preview-window hidden --layout='.shellescape(<SID>open_floatingWin_fzf_layout())})

" ------------------------------------------------------------------
" Directory And FileName Selector
" ------------------------------------------------------------------
imap <expr> <C-_> fzf#complete({
    \ 'source': <SID>dir_file_completion(<SID>fzf_last_word()),
    \ 'reducer': function('<SID>dir_file_sink'),
    \ 'window': 'call OpenFloatingWin()',
    \ 'options': '-m -x --ansi --preview-window hidden --print-query --layout='.shellescape(<SID>open_floatingWin_fzf_layout())})

function! s:dir_file_completion(word)
  " return  systemlist("fd --follow --hidden --color=always --exclude .git '^" . a:word . "' | tr '/' '\n' | sort | uniq")
  return  systemlist("fd --strip-cwd-prefix --follow --hidden --color=always --exclude .git '^" . a:word . "' | sort | uniq")
endfunction

function! s:dir_file_sink(lines)
  let rmpath = substitute(a:lines[1],'.\+'.a:lines[0],a:lines[0],'g')
  return rmpath
endfunction

" ------------------------------------------------------------------
" JunkFile Navigator
" ------------------------------------------------------------------
command! -nargs=* Memo call fzf#run({
  \  'source': s:junk_file_list(),
  \  'sink*': function('<SID>junk_file_sink'),
  \  'options': '-m -x --ansi --preview-window hidden --prompt=Memo:'.shellescape(<q-args>),
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
  let workdir = s:get_root_dir_for_junk()
  execute "edit +" . split(a:line[0], ':')[1] . " ~/.cache/junkfile/". workdir . '/' . split(a:line[0], ':')[0]
endfunction

" ------------------------------------------------------------------
" Git Navigator
" ------------------------------------------------------------------
command! -nargs=* Gitignore call fzf#run({
  \  'source': s:ignore_file_list(),
  \  'sink*': function('<SID>ignore_file_sink'),
  \  'options': '--prompt=Gitignore: --query '.shellescape(<q-args>) . ' -m -x ' .
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
    call feedkeys("\<cmd>AddGitignore\<CR>")
    return
  endif
  " execute("Gina add " . fnamemodify(a:lines[0], ":p"))
  call feedkeys("\<cmd>Gitignore " . a:lines[0] . "\<CR>")
  return
endfunction

command! -nargs=* AddGitignore call fzf#run({
  \  'source': <SID>dir_file_completion(''),
  \  'sink*': function('<SID>add_ignore_file_sink'),
  \  'options': '--prompt=AllGitignore: --query '.shellescape(<q-args>) . ' -m -x ' .
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
      execute("Git rm --cached " . fnamemodify(t, ":p"))
    endfor
    call feedkeys("\<cmd>AddGitignore " . a:lines[0] . "\<CR>")
    return
  elseif a:lines[1] == 'ctrl-t'
    call feedkeys("\<cmd>Gitignore\<CR>")
    return
  endif
  execute("Git rm --cached " . fnamemodify(a:lines[2], ":p"))
  execute("silent !echo " . a:lines[2] . " >> " . s:dir . "/.gitignore")
endfunction

function! s:override_gitfiles_source()
  return  systemlist("git ls-files | $XDG_CONFIG_HOME/nvim/bin/color-ls")
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
      execute("Git rm --cached " . a:lines[w])
    endfor
    call feedkeys("\<cmd>GFiles\<CR>")
    return
  endif
  for w in range(1, len(a:lines) - 1)
    execute("edit ". fnamemodify(a:lines[w], ":p"))
  endfor
endfunction

command! -bang -nargs=? -complete=dir GFiles
  \ call fzf#vim#gitfiles(<q-args>, fzf#wrap('fzf',
  \ {'source': <SID>override_gitfiles_source(),
  \  'sink*': function('<SID>override_gitfiles_sink'),
  \  'options': "-m -x --no-unicode --ansi
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

function! FZFYankInsertHandler(line) abort
  let yank = substitute(a:line[0], '\d\+\s', '', '')
  let yank = substitute(yank, '⏎\s\+', '⏎', 'g')
  let yank = substitute(yank, '⏎', '\r', 'g')
  return yank
endfunction

command! YanksAfter call fzf#run(fzf#wrap('YanksAfter', {
\ 'source':  FZFYankList(),
\ 'window': 'call OpenFloatingWin()',
\ 'sink':    function('FZFYankHandler', ['p']),
\ 'options': '--preview-window hidden --no-sort',
\ }))

command! YanksBefore call fzf#run(fzf#wrap('YanksBefore', {
\ 'source':  FZFYankList(),
\ 'window': 'call OpenFloatingWin()',
\ 'sink':    function('FZFYankHandler', ['P']),
\ 'options': '--preview-window hidden --no-sort',
\ }))

imap <expr> <M-y> fzf#complete({
    \ 'source': FZFYankList(),
    \ 'reducer': function('FZFYankInsertHandler'),
    \ 'window': 'call OpenFloatingWin()',
    \ 'options': '--preview-window hidden --no-sort'})

" ------------------------------------------------------------------
" Buffer Navigator
" ------------------------------------------------------------------
function! s:bufopen(lines)
  if len(a:lines) < 3
    return
  endif

  if a:lines[1] == 'ctrl-k'
    execute('bwipeout')
    call feedkeys("\<cmd>NavBuffers " . a:lines[0] . "\<CR>")
    return
  endif

  if a:lines[1] == 'ctrl-d'
    for w in range(2, len(a:lines) - 1)
      let b = a:lines[w]
      let index = matchstr(b, '^\[\([0-9a-f]\+\)\]')
      execute('bwipeout ' . index[1:len(index)-2])
    endfor
    call feedkeys("\<cmd>NavBuffers " . a:lines[0] . "\<CR>")
    return
  endif

  if a:lines[1] == 'ctrl-b'
    let index = matchstr(a:lines[2], '\[\zs[0-9]*\ze\]')
    execute ('buffer ' . index)
    call feedkeys("\<cmd>NavBuffers " . a:lines[0] . "\<CR>")
    return
  endif

  if a:lines[1] == 'ctrl-q'
    let returnArr = []
    for w in range(2, len(a:lines) - 1)
      let split = split(a:lines[w], ' ')
      call add(returnArr, split[3] . split[1])
    endfor
    call setqflist(map(copy(returnArr), '{ "filename": v:val }'))
    copen
    cc
  endif

  let b = matchstr(a:lines[2], '\[\zs[0-9]*\ze\]')
  let cmd = get(g:fzf_action, a:lines[1])
  if !empty(cmd)
    execute 'silent ' cmd
    execute 'buffer ' b
    call feedkeys("\<cmd>NavBuffers " . a:lines[0] . "\<CR>")
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
  \   '\t', '-n', '2,4', '--prompt', 'Buf> ', '--query', <q-args>,
  \   '--header', ':: Press C-D Del C-b Preview And Default Key Working',
  \   '--delimiter', ' ', '--preview', 'bat --style=changes --color=always  {4}{2}', '--preview-window', 'hidden',
  \   '--print-query', '--expect=ctrl-d,ctrl-b,ctrl-x,ctrl-v,ctrl-k,ctrl-q', '--no-unicode'],
  \   'up': '30%',
  \ }))

" ------------------------------------------------------------------
" ChangeList Navigator
" ------------------------------------------------------------------
function! s:getChenges()
  if !filereadable(expand('%'))
    return []
  endif

  let lists = []
  let nums = map(copy(getchangelist('%')[0]), { _, change -> [change['lnum'], change['col']] })
  for num in nums
    let lines = getbufline(bufnr('%'), num[0])
    if len(lines) > 0
      call add(lists, [num[0], num[1], lines[0]])
    endif
  endfor
  call reverse(lists)

  let result = []
  for item in lists
    if match(result, item[0]) == -1
      call add(result, item)
    endif
  endfor

  return map(s:align_lists(result), { _, v -> join(v, '  ') })

endfunction

function! s:align_lists(lists) abort
  let maxes = {}
  for list in a:lists
    let i = 0
    while i < len(list)
      let maxes[i] = max([get(maxes, i, 0), len(list[i])])
      let i += 1
    endwhile
  endfor
  for list in a:lists
    call map(list, { key, v -> printf('%-' . maxes[key] . 's', substitute(v,'^\s\+', '' , '')) })
  endfor
  return a:lists
endfunction

function! s:changeCursorMove(line)
  execute "call cursor(" . split(a:line[0], '\s\+')[0] . "," . split(a:line[0], '\s\+')[1] . ")"
endfunction

command! -nargs=* ChangeListNav call fzf#run({
  \  'source': s:getChenges(),
  \  'sink*':   function('<SID>changeCursorMove'),
  \  'options': '--reverse -m -x --ansi --preview "$HOME/.config/zsh/preview_fzf_grep ' . expand('%') . ':{}" --prompt=ChangeList:',
  \  'down': '40%'})

" ------------------------------------------------------------------
" JumpList Navigator
" ------------------------------------------------------------------
function! s:getjumps()
  let splited_project_path = split(FindRootDirectory(), '/')
  let bufnr_and_lnum_list = map(copy(getjumplist()[0]), {
  \ _, jump -> { 'bufnr': jump['bufnr'], 'lnum': jump['lnum'], 'cnum': jump['col'] }
  \ })

  let result = s:convert_line(bufnr_and_lnum_list, splited_project_path)

  call reverse(result)
  return s:color_filename_grep(result)
endfunction

function! s:convert_line(bufnr_and_lnum_list, splited_project_path) abort
  let result = []
  for bufnr_and_lnum in a:bufnr_and_lnum_list
    let bufnr = bufnr_and_lnum['bufnr']
    let lnum = bufnr_and_lnum['lnum']
    let cnum = bufnr_and_lnum['cnum']
    let bufinfos = getbufinfo(bufnr)

    if len(bufinfos) > 0
      let bufinfo = bufinfos[0]
      let file = bufinfo['name']

      if s:is_project_file(file, a:splited_project_path) && filereadable(file)
        let file = fnamemodify(file, ':.')
        let line_number = lnum
        let column_number = cnum
        let lines = systemlist('sed -n ' . lnum . 'p ' . file)

        if len(lines) > 0
          let text = substitute(lines[0],'^\s\+', '' , '')
        else
          let text = ''
        endif

        call add(result, file . ':' . line_number . ':' . column_number . ': ' . text)
      endif
    endif
  endfor

  return result
endfunction

function! s:jumpCursorMove(line)
  if filereadable(fnamemodify(split(a:line[0], ':')[0], ':p'))
    execute "e " . fnamemodify(split(a:line[0], ':')[0], ':p')
    execute "call cursor(" . split(a:line[0], ':')[1] . "," . split(a:line[0], ':')[2] . ")"
  else
    execute "call cursor(" . split(a:line[0], ':')[1] . "," . split(a:line[0], ':')[2] . ")"
  endif
endfunction

command! -nargs=* JumpListNav call fzf#run({
  \  'source': s:getjumps(),
  \  'sink*':   function('<SID>jumpCursorMove'),
  \  'options': '--reverse -m -x --ansi --preview "$HOME/.config/zsh/preview_fzf_grep {}" --prompt=JumpList:',
  \  'down': '40%'})

" ------------------------------------------------------------------
" MarkList Navigator
" ------------------------------------------------------------------
function! s:getmarks()
  let splited_project_path = split(FindRootDirectory(), '/')

  let chars = [
  \ 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm',
  \ 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z',
  \ 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M',
  \ 'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z',
  \ ]

  let bufnr_and_lnum_list = map(map(copy(chars), {
  \ _, char -> getpos("'" . char)
  \ }), {
  \ _, pos -> { 'bufnr': pos[0] == 0 ? bufnr('%') : pos[0], 'lnum': pos[1], 'cnum': pos[2] }
  \ })
  call filter(bufnr_and_lnum_list, { _, bufnr_and_lnum -> bufnr_and_lnum['lnum'] != 0 })

  let result = s:convert_line(bufnr_and_lnum_list, splited_project_path)
  return s:color_filename_grep(result)
endfunction

function! s:markCursorMove(line)
  if filereadable(fnamemodify(split(a:line[0], ':')[0], ':p'))
    execute "e " . fnamemodify(split(a:line[0], ':')[0], ':p')
    execute "call cursor(" . split(a:line[0], ':')[1] . "," . split(a:line[0], ':')[2] . ")"
  else
    execute "call cursor(" . split(a:line[0], ':')[1] . "," . split(a:line[0], ':')[2] . ")"
  endif
endfunction

command! -nargs=* MarkListNav call fzf#run({
  \  'source': s:getmarks(),
  \  'sink*':   function('<SID>markCursorMove'),
  \  'options': '--reverse -m -x --ansi --preview "$HOME/.config/zsh/preview_fzf_grep {}" --prompt=MarkList:',
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
  \  'options': '--reverse -m -x --ansi --prompt=Highlight:',
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
  \  'options': '--reverse -m -x --ansi --prompt=PhpRefactorMenu:',
  \  'down': '20%'})

" ------------------------------------------------------------------
" QuickFix
" ------------------------------------------------------------------
command! Fq FZFQuickfix
command! FZFQuickfix call fzf#run({
  \  'source':  Get_qf_text_list(),
  \  'sink':    function('s:qf_sink'),
  \  'options': '-m -x',
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

" ------------------------------------------------------------------
" Help tags
" ------------------------------------------------------------------
command! -bang -nargs=? -complete=dir Helptags
  \ call fzf#vim#helptags({'options': []}, <bang>0)

" ------------------------------------------------------------------
" utils
" ------------------------------------------------------------------
function! s:color_filename(files) abort
  let files = copy(a:files)
  let result = systemlist('echo -e "' . join(files, '\n') . '" | xargs -d "\n" $XDG_CONFIG_HOME/nvim/bin/color-ls')

  return result
endfunction

function! s:color_filename_grep(files) abort
  " meny lines very slow
  let result = []

  for line in copy(a:files)
    let splitline = split(line, ':')
    let file = splitline[0]
    call remove(splitline, 0)
    " preview not working
    " let cfile = system('echo -e "' . file . '" | xargs exa --color=always')
    let cfile = "\033[38;2;102;204;0m" . file . "\033[0m"
    call insert(splitline, cfile, 0)
    let export = join(splitline, ':')
    call add(result, export)
  endfor

  return result
endfunction

function! s:create_dev_icon_list(files) abort
  let result = []

  for file in copy(a:files)
    let file = split(file, ':')[0]
    let filename = fnamemodify(file, ':p:t')
    let icon = WebDevIconsGetFileTypeSymbol(substitute(filename, '\[[0-9;]*m', '', 'g'), isdirectory(filename))
    call add(result, s:dev_icon_format(icon, filename))
  endfor

  return result
endfunction

function! s:dev_icon_format(icon, filename) abort
  return printf('%s  %s', a:icon, a:filename)
endfunction

function! s:is_project_file(file, splited_project_path) abort
  let splited_file_path = split(a:file, '/')

  let is_project_file = 1
  let index = 0
  for dir_name in a:splited_project_path[:len(splited_file_path) - 1]
    if dir_name !=# splited_file_path[index]
      let is_project_file = 0
    endif
    let index = index + 1
  endfor

  return is_project_file
endfunction
