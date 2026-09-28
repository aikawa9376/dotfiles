" Fallback highlighting for .http/.rest files and response headers.
if exists('b:current_syntax')
  finish
endif

syntax include @OverseerHttpJson syntax/json.vim
syntax case match

syntax match OverseerHttpComment /^#\s.*$/
syntax match OverseerHttpSeparator /^\s*###.*$/
syntax match OverseerHttpStatus /^HTTP\/\S\+\s\+\d\{3\}.*$/
syntax match OverseerHttpRequest /^\s*\%(GET\|POST\|PUT\|PATCH\|DELETE\|HEAD\|OPTIONS\)\s\+\S.*$/ contains=OverseerHttpMethod,OverseerHttpUrl,OverseerHttpVariable
syntax match OverseerHttpMethod /^\s*\%(GET\|POST\|PUT\|PATCH\|DELETE\|HEAD\|OPTIONS\)\ze\s/ contained
syntax match OverseerHttpUrl /\s\zs\S\+\ze\s*$/ contained
syntax match OverseerHttpHeader /^\s*[A-Za-z0-9-]\+\s*:.*$/ contains=OverseerHttpHeaderName,OverseerHttpVariable
syntax match OverseerHttpHeaderName /^\s*[A-Za-z0-9-]\+\ze\s*:/ contained
syntax region OverseerHttpJsonBody start=/^\s*{/ end=/^\s*###/me=s-1 keepend transparent contains=@OverseerHttpJson,OverseerHttpVariable
syntax region OverseerHttpJsonBody start=/^\s*\[/ end=/^\s*###/me=s-1 keepend transparent contains=@OverseerHttpJson,OverseerHttpVariable
syntax match OverseerHttpVariable /{{\s*\w\+\s*}}/ containedin=ALL

highlight default link OverseerHttpComment Comment
highlight default link OverseerHttpSeparator Title
highlight default link OverseerHttpStatus Constant
highlight default link OverseerHttpRequest Normal
highlight default link OverseerHttpMethod Statement
highlight default link OverseerHttpUrl Underlined
highlight default link OverseerHttpHeader Normal
highlight default link OverseerHttpHeaderName Type
highlight default link OverseerHttpVariable Special

let b:current_syntax = 'overseer_http'
