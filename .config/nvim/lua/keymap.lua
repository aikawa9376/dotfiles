local function map(mode, lhs, rhs, opts)
  local options = {noremap = true}
  if opts then options = vim.tbl_extend('force', options, opts) end
  vim.api.nvim_set_keymap(mode, lhs, rhs, options)
end

map('n', '<Space>', '<Leader>', { noremap = false })
map('v', '<Space>', '<Leader>', { noremap = false })
map('x', '<Space>', '<Leader>', { noremap = false })
map('o', '<Space>', '<Leader>', { noremap = false })
map('n', '<Leader>z', ':BufOnly<CR>')
map('n', 'x', '"_x')
map('v', 'x', '"_x')
map('n', 'cl', '"_s')
map('v', 'cl', '"_s')
map('v', '<', '<gv')
map('v', '>', '>gv')
map('n', '<Leader>i', 'mzgg=G`z')
map('n', '<CR>', 'i<CR><Esc>==')
map('n', '<Leader><CR>', '$a<CR><Esc>')
map('n', '<Leader>s', 'i<Space><ESC>')
map('n', ']<space>', 'mzo<ESC>`zj')
map('n', '[<space>', 'mzO<ESC>`zk')
map('n', 'X', 'diw')
map('i', '<C-a>', '<C-g>U<C-o>^')
map('i', '<C-e>', '<C-g>U<C-o>$<C-g>U<Right>')
map('i', '<C-b>', '<C-g>U<Left>')
map('i', '<C-f>', '<C-g>U<Right>')
map('i', '<C-n>', '<C-g>U<Down>')
map('i', '<C-p>', '<C-g>U<Up>')
map('i', '<C-h>', '<C-g>U<BS>')
map('i', '<C-d>', '<C-g>U<Del>')
map('i', '<C-k>', '<C-g>U<C-o>D<Right>')
map('i', '<C-u>', '<C-g>U<C-o>d^')
map('i', '<C-w>', '<C-g>U<C-o>db')
map('i', '<M-f>', '<C-g>U<C-o>w')
map('i', '<M-b>', '<C-g>U<C-o>b')
map('i', '<M-p>', '<C-g>U<C-o>P')
map('i', '<C-v>', '<C-g>U<C-o>yh<C-g>U<C-r>"<C-g>U<Right>')
map('n', 'Y', 'y$')
map('n', 'V', 'v$')
map('n', 'vv', 'V')
map('n', 'gV', '\'`[\'.strpart(getregtype(), 0, 1).\'`]\'', { noremap = true, expr = true, silent = true })
map('n', 'y', 'm`mvmry')
map('v', 'y', 'm`mvmry')
map('n', 'v', 'm`mvv')
map('n', 'd', 'm`mvd')
map('n', 'c', 'm`mvc')
map('n', ':', 'm`mv:')
map('n', '=', 'm`mv=')
map('n', '=f', 'mv`[=`]`v')
map('n', '<C-v>', 'mv<C-v>')
map('n', '<M-x>', 'vy')
map('n', '<C-h>', '^')
map('v', '<C-h>', '^')
map('n', '<C-l>', '$l')
map('v', '<C-l>', '$l')
map('n', '<M-m>', ':call cursor(0,strlen(getline("."))/2)<CR>', { noremap = true, silent = true })
map('n', '<M-l>', 'i<Space><ESC><Right>')
map('n', '<M-h>', 'hx')
map('n', '<M-j>', 'j:call cursor(0,strlen(getline("."))/2)<CR>', { noremap = true, silent = true })
map('n', '<M-k>', 'k:call cursor(0,strlen(getline("."))/2)<CR>', { noremap = true, silent = true })
map('n', ']n', 'ngn<ESC>')
map('n', '[n', 'Ngn<ESC>')
map('n', 'gj', 'J')
map('i', 'jj', '<Esc>', { noremap = true, silent = true })
map('i', 'っｊ', '<Esc>', { noremap = true, silent = true })
map('n', 'っｊ', 'Fcitx2en()', { noremap = true, expr = true, silent = true })
map('n', 'n', 'nzz')
map('n', 'N', 'Nzz')
map('n', 'Y', 'y$')
map('n', 'V', 'v$')
map('n', 'vv', 'V')
map('n', '|', ':<c-u>vsplit<CR><C-w>h', { noremap = true, silent = true })
map('n', '-', ':<c-u>split<CR><C-w>k', { noremap = true, silent = true })
map('n', '<C-q>', '@q')
map('n', '<Leader>rw', ':%s///g<Left><Left><Left>')
map('n', '<Leader>rW', ':%s/<c-r>=expand("<cword>")<cr>//g<Left><Left>')
map('v', '<Space>rw', 'y:%s/<c-r>"//g<Left><Left><Left>')
map('n', '<M-;>', 'mz$a;<ESC>`z')
map('n', '<M-,>', 'mz$a,<ESC>`z')
map('i', '<C-l>', '<C-x><C-l>')
map('n', 'cd', ':lcd %:p:h<bar>pwd<cr>')
map('n', 'cu', ':lcd ..<bar>pwd<cr>')
map('c', '<C-b>', '<Left>')
map('c', '<C-f>', '<Right>')
map('c', '<C-a>', '<Home>')
map('c', '<C-e>', '<End>')
map('c', '<C-d>', '<Del>')
map('c', '<C-Y>', '<C-R>-')
map('n', '<Leader>', '<Nop>')
map('n', '<Leader>w', ':<c-u>w<CR>', { noremap = true, silent = true })
map('n', '<Leader>W', ':bufdo! w<CR>', { noremap = true, silent = true })
map('n', '<Leader>x', ':<c-u>Bdelete<CR>', { noremap = true, silent = true })
map('n', '<Leader>X', ':<c-u>bd<CR>', { noremap = true, silent = true })
map('n', 'ZZ', ':<c-u>xa<CR>', { noremap = true, silent = true })
map('n', '<M-b>', ':bnext<CR>', { noremap = true, silent = true })
map('n', '<C-g>', 'm`<C-^>', { noremap = true, silent = true })
map('t', '<C-[>', '<C-\\><C-n>', { noremap = true, silent = true })

-- nvim-cmp mapping
map('s', '<C-Space>', ' <BS>', { noremap = true })
