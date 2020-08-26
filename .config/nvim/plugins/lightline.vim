let g:lightline = {
  \ 'colorscheme': 'nordplus',
  \ 'mode_map': {'c': 'NORMAL'},
  \ 'active': {
    \ 'left': [
      \ ['mode', 'paste', 'spell', 'help'],
      \ ['vm_regions', 'gitgutter', 'project', 'filename'],
    \ ],
    \ 'right': [
        \ ['cocstatus'],
        \ ['lineinfo'],
        \ ['filetype', 'fileencoding', 'charcode'],
        \ ['vm_modes'],
    \   ]
  \ },
  \ 'tabline': {
    \ 'left': [
      \ ['buffers']
    \ ],
    \ 'right': [
      \ ['workbench', 'obsession'],
    \ ]
  \ },
  \ 'component': {
    \ 'lineinfo': '☰ %2p%% %2l:%v'
  \ },
  \ 'component_function': {
    \ 'mode'           : 'MyMode',
    \ 'modified'       : 'MyModified',
    \ 'readonly'       : 'MyReadonly',
    \ 'project'        : 'MyProject',
    \ 'filename'       : 'MyFilename',
    \ 'filetype'       : 'MyFiletype',
    \ 'fileencoding'   : 'MyFileencoding',
    \ 'charcode'       : 'MyCharCode',
    \ 'gitgutter'      : 'MyGitGutter',
    \ 'vm_modes'       : 'g:lightline.vm_modes',
    \ 'vm_regions'     : 'g:lightline.vm_regions',
    \ 'obsession'      : 'MyObsession',
    \ 'workbench'      : 'MyWorkbench',
    \ 'cocstatus'      : 'coc#status',
    \ },
  \ 'component_expand': {
    \ 'buffers'        : 'lightline#bufferline#buffers'
  \ },
  \ 'component_type': {
    \ 'linter_checking': 'left',
    \ 'linter_ok'      : 'left',
    \ 'linter_warnings': 'warning',
    \ 'linter_errors'  : 'error',
    \ 'buffers'        : 'tabsel'
  \ },
  \ 'component_function_visible_condition': {
    \ 'vm_modes'       : 'g:lightline.VM()',
    \ 'vm_regions'     : 'g:lightline.VM()',
  \ },
  \ 'separator'        : {'left': "", 'right': ""},
  \ 'subseparator'     : {'left': "", 'right': ""}
\ }

function! MyMode()
  return  &ft == 'denite'    ? 'denite' :
        \ &ft == 'defx'      ? 'defx' :
        \ &ft == 'fzf'       ? 'fzf' :
        \ &ft == 'mundo'     ? 'mundo' :
        \ &ft == 'MundoDiff' ? 'diff' :
        \ g:lightline.VM()   ? g:lightline.vm_mode() :
        \ winwidth(0) > 20   ? g:lightline#mode() : ''
endfunction

function! MyModified()
  return &ft =~ 'help\|defx\|mundo' ? '' : &modified ? '+' : &modifiable ? '' : '-'
endfunction

function! MyObsession()
  if exists('*ObsessionStatus')
    return ObsessionStatus("\uf0c7", '')
  else
    return ''
  endif
endfunction

function! MyWorkbench()
  if exists('*SWSqlLightLineProfile')
    let s:db = SWSqlLightLineProfile()
    if s:db != ''
      return "\uf472" . ' ' . s:db
    else
      return ''
    endif
  else
    return ''
  endif
endfunction

function! MyReadonly()
  return &ft !~? 'help\|defx\|mundo' && &ro ? "\u2b64" : ''
endfunction

function! MyFilename()
  return WebDevIconsGetFileTypeSymbol() . ' ' . ('' != MyReadonly() ? MyReadonly() . ' ' : '') .
  \ (&ft == 'defx'      ? 'files' :
  \  &ft == 'denite'    ? denite#get_status_string() :
  \  &ft == 'mundo'     ? 'undo' :
  \  &ft == 'MundoDiff' ? 'preview' :
  \  &ft == 'fzf'       ? 'search' :
  \  &ft == 'vimshell'  ? substitute(b:vimshell.current_dir,expand('~'),'~','') :
  \  winwidth(0) < 100  ? expand("%:t") :
  \  '' != @%           ? @% : '[No Name]') .
  \ ('' != MyModified() ? ' ' . MyModified() : '')
endfunction

function! MyRootDir()
  if exists('*FindRootDirectory') && FindRootDirectory() != ''
    let s:dir = FindRootDirectory()
    let s:dir = split(s:dir, '/')
    return "\ue5fe " . s:dir[len(s:dir) - 1]
  else
    return ''
  endif
endfunction

function! MyFugitive()
  try
    if &ft !~? 'help\|defx\|mundo' && exists('*fugitive#head')
      let _ = fugitive#head()
      return strlen(_) ? "\u2b60 "._ : ''
    endif
  catch
  endtry
  return ''
endfunction

function! MyProject()
  let s:prod = ''
  if MyFugitive() != ''
    let s:prod = MyFugitive()
  endif
  if s:prod == ''
    let s:prod = MyRootDir()
  else
    let s:prod = s:prod . ' ' . MyRootDir()
  endif
  return winwidth('.') > 100 ? s:prod : ''
endfunction

function! MyFiletype()
  return winwidth('.') > 70 ? (strlen(&filetype) ? WebDevIconsGetFileTypeSymbol() . ' ' . &filetype : 'no ft') : ''
endfunction

function! MyFileencoding()
  return winwidth('.') > 70 ? WebDevIconsGetFileFormatSymbol() . ' ' . (strlen(&fenc) ? &fenc : &enc) : ''
endfunction

function! MyGitGutter()
  if ! exists('*GitGutterGetHunkSummary')
  \ || ! get(g:, 'gitgutter_enabled', 0)
  \ || winwidth('.') <= 100
    return ''
  endif
  let symbols = [
    \ g:gitgutter_sign_added    . '',
    \ g:gitgutter_sign_modified . '',
    \ g:gitgutter_sign_removed  . ''
  \ ]
  let hunks = GitGutterGetHunkSummary()
  let ret = []
  for i in [0, 1, 2]
    if hunks[i] > 0
      call add(ret, symbols[i] . hunks[i])
    endif
  endfor
  return winwidth('.') > 70 ? join(ret, ' ') : ''
endfunction

let g:lightline.VM = { -> exists("g:Vm") && g:Vm.buffer }

fun! g:lightline.vm_mode() dict
  if g:lightline.VM()
    call lightline#link('v')
    return "V-MULTI"
  endif
endfun

fun! g:lightline.vm_modes() dict
  if g:lightline.VM()
    let v = g:Vm
    let V = b:VM_Selection.Vars
    let m = v.mappings_enabled ? 'M' : 'm'
    let o = V.single_region    ? 'O' : 'o'
    let l = V.multiline        ? 'V' : 'v'
    return m.o.l
  endif
  return ''
endfun

fun! g:lightline.vm_regions() dict
  if g:lightline.VM()
    let V = b:VM_Selection.Vars
    let i = V.index + 1
    let max = len(b:VM_Selection.Regions)
    return i.' / '.max
  endif
  return ''
endfun
