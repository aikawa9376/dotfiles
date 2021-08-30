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
