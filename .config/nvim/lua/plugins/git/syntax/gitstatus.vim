" Standalone status syntax; no runtime dependency on another Git UI provider.
if exists('b:current_syntax')
  finish
endif

syn sync fromstart
syn spell notoplevel
syn include @gitDiff syntax/diff.vim

syn match gitHeader /^[A-Z][a-z][^:]*:/
syn match gitHeader /^Head:/ nextgroup=gitHash,gitSymbolicRef skipwhite
syn match gitHeader /^Upstream:\|^Remote:\|^Pull:\|^Rebase:\|^Merge:/ nextgroup=gitSymbolicRef skipwhite
syn match gitAheadBehind /(+\d\+\/-\d\+)/

syn region gitSection start=/^\%(Tags\?:\)\@!\%(.*(\d\++\=)$\)\@=/ contains=gitHeading end=/^$/ fold
syn cluster gitSection contains=gitSection
syn match gitHeading /^[A-Z][a-z][^:]*\ze (\d\++\=)$/ contains=gitPreposition contained nextgroup=gitCount skipwhite
syn match gitCount /(\d\++\=)/hs=s+1,he=e-1 contained
syn match gitPreposition /\<\%([io]nto\|from\|to\|Rebasing\%( detached\)\=\)\>/ transparent contained nextgroup=gitHash,gitSymbolicRef skipwhite

syn match gitInstruction /^\l\l\+\>/ contained containedin=@gitSection nextgroup=gitHash skipwhite
syn match gitDone /^done\>/ contained containedin=@gitSection nextgroup=gitHash skipwhite
syn match gitStop /^stop\>/ contained containedin=@gitSection nextgroup=gitHash skipwhite
syn match gitModifier /^[MADRCU?]\{1,2} / contained containedin=@gitSection
syn match gitSymbolicRef /\.\@!\%(\.\.\@!\|[^[:space:][:cntrl:]\:.]\)\+\.\@<!/ contained
syn match gitHash /^\x\{4,\}\S\@!/ contained containedin=@gitSection
syn match gitHash /\S\@<!\x\{4,\}\S\@!/ contained

syn region gitHunk start=/^\%(@@\+ -\)\@=/ end=/^\%([A-Za-z?@]\|$\)\@=/ contains=diffLine,diffRemoved,diffAdded,diffNoEOL containedin=@gitSection fold

for s:section in ['Untracked', 'Unstaged', 'Staged']
  exe 'syn region git' . s:section . 'Section start=/^\%(' . s:section . ' .*(\d\++\=)$\)\@=/ contains=git' . s:section . 'Heading end=/^$/ fold'
  exe 'syn match git' . s:section . 'Modifier /^[MADRCU?] / contained containedin=git' . s:section . 'Section'
  exe 'syn cluster gitSection add=git' . s:section . 'Section'
  exe 'syn match git' . s:section . 'Heading /^[A-Z][a-z][^:]*\ze (\d\++\=)$/ contains=gitPreposition contained nextgroup=gitCount skipwhite'
endfor
unlet s:section

hi def link gitHeader Label
hi def link gitHeading PreProc
hi def link gitUntrackedHeading PreCondit
hi def link gitUnstagedHeading Macro
hi def link gitStagedHeading Include
hi def link gitModifier Type
hi def link gitUntrackedModifier StorageClass
hi def link gitUnstagedModifier Structure
hi def link gitStagedModifier Typedef
hi def link gitInstruction Type
hi def link gitStop Function
hi def link gitHash Identifier
hi def link gitSymbolicRef Function
hi def link gitCount Number
hi def link gitAheadBehind Number

let b:current_syntax = 'gitstatus'
