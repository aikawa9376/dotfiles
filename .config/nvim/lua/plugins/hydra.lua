local Hydra = require('hydra')
-- 何故かrequreしないと存在が無い
local diagnostic = require('vim.diagnostic')

Hydra({
  name = 'Buffer',
  mode = 'n',
  body = ']b',
  config = {
    hint = false,
    invoke_on_body = true,
    on_enter = function()
      vim.cmd 'bnext'
    end
  },
  heads = {
    { ']', '<cmd>bnext<CR>' },
    { '[', '<cmd>bpreviou<CR>' },
  }
})
Hydra({
  name = 'Buffer',
  mode = 'n',
  body = '[b',
  config = {
    hint = false,
    invoke_on_body = true,
    on_enter = function()
      vim.cmd 'bpreviou'
    end
  },
  heads = {
    { ']', '<cmd>bnext<CR>' },
    { '[', '<cmd>bpreviou<CR>' },
  }
})

Hydra({
  name = 'History',
  mode = 'n',
  body = 'g;',
  config = {
    hint = false,
    invoke_on_body = true,
    on_enter = function()
      vim.fn.feedkeys(vim.api.nvim_replace_termcodes('g;', true, true, true), 'n')
    end
  },
  heads = {
    { ';', 'g;' },
    { ',', 'g,' },
  }
})
Hydra({
  name = 'History',
  mode = 'n',
  body = 'g,',
  config = {
    hint = false,
    invoke_on_body = true,
    on_enter = function()
      vim.fn.feedkeys(vim.api.nvim_replace_termcodes('g,', true, true, true), 'n')
    end
  },
  heads = {
    { ';', 'g;' },
    { ',', 'g,' },
  }
})

Hydra({
  name = 'Yank',
  mode = { 'n', 'x' },
  body = 'p',
  config = {
    hint = false,
    invoke_on_body = true,
    on_enter = function()
      vim.fn.feedkeys(
        vim.api.nvim_replace_termcodes('<Plug>(miniyank-autoput)', true, true, true), 'n')
    end
  },
  heads = {
    { '<C-p>', '<Plug>(miniyank-cycle)' },
    { '<C-n>', '<Plug>(miniyank-cycleback)' },
    { '<C-w>', '<Plug>(miniyank-tochar)' },
    { '<C-l>', '<Plug>(miniyank-toline)' },
    { '<C-b>', '<Plug>(miniyank-toblock)' },
    { '<C-f>', '=`]^' },
  }
})
Hydra({
  name = 'Yank',
  mode = { 'n', 'x' },
  body = 'P',
  config = {
    hint = false,
    invoke_on_body = true,
    on_enter = function()
      vim.fn.feedkeys(
        vim.api.nvim_replace_termcodes('<Plug>(miniyank-autoPut)', true, true, true), 'n')
    end
  },
  heads = {
    { '<C-p>', '<Plug>(miniyank-cycle)' },
    { '<C-n>', '<Plug>(miniyank-cycleback)' },
    { '<C-w>', '<Plug>(miniyank-tochar)' },
    { '<C-l>', '<Plug>(miniyank-toline)' },
    { '<C-b>', '<Plug>(miniyank-toblock)' },
    { '<C-f>', '=`]^' },
  }
})

Hydra({
  name = 'SearchExD',
  mode = 'n',
  body = ']n',
  config = {
    hint = false,
    invoke_on_body = true,
    on_enter = function()
      vim.fn.feedkeys(
        vim.api.nvim_replace_termcodes('ngn<Esc>', true, true, true), 'n')
    end
  },
  heads = {
    { 'n', 'ngn<Esc>' },
  }
})
Hydra({
  name = 'SearchExU',
  mode = 'n',
  body = '[n',
  config = {
    hint = false,
    invoke_on_body = true,
    on_enter = function()
      vim.fn.feedkeys(
        vim.api.nvim_replace_termcodes('Ngn<Esc>', true, true, true), 'n')
    end
  },
  heads = {
    { 'n', 'Ngn<Esc>' },
  }
})

Hydra({
  name = 'Chunk',
  mode = 'n',
  body = ']c',
  config = {
    hint = false,
    invoke_on_body = true,
    on_enter = function()
      vim.cmd 'GitGutterNextHunk'
    end
  },
  heads = {
    { ']', '<cmd>GitGutterNextHunk<CR>' },
    { '[', '<cmd>GitGutterPrevHunk<CR>' },
  }
})
Hydra({
  name = 'Chunk',
  mode = 'n',
  body = '[c',
  config = {
    hint = false,
    invoke_on_body = true,
    on_enter = function()
      vim.cmd 'GitGutterPrevHunk'
    end
  },
  heads = {
    { ']', '<cmd>GitGutterNextHunk<CR>' },
    { '[', '<cmd>GitGutterPrevHunk<CR>' },
  }
})

Hydra({
  name = 'QuickFix',
  mode = 'n',
  body = ']q',
  config = {
    hint = false,
    invoke_on_body = true,
    on_enter = function()
      vim.fn.feedkeys(
        vim.api.nvim_replace_termcodes('<Plug>(qutefinger-next)', true, true, true), 'n')
    end
  },
  heads = {
    { ']', '<Plug>(qutefinger-next)' },
    { '[', '<Plug>(qutefinger-prev)' },
  }
})
Hydra({
  name = 'QuickFix',
  mode = 'n',
  body = '[q',
  config = {
    hint = false,
    invoke_on_body = true,
    on_enter = function()
      vim.fn.feedkeys(
        vim.api.nvim_replace_termcodes('<Plug>(qutefinger-prev)', true, true, true), 'n')
    end
  },
  heads = {
    { ']', '<Plug>(qutefinger-next)' },
    { '[', '<Plug>(qutefinger-prev)' },
  }
})

Hydra({
  name = 'Linter',
  mode = 'n',
  body = ']a',
  config = {
    hint = false,
    invoke_on_body = true,
    on_enter = function()
      diagnostic.goto_next({ float = false })
      diagnostic.open_float(nil, { border = 'rounded', scope = 'cursor', focusable = false })
    end
  },
  heads = {
    { ']',
      "<cmd>lua vim.diagnostic.goto_next({float = false})<CR><cmd>lua vim.diagnostic.open_float(nil, { border = 'rounded', scope = 'cursor',  focusable = false })<CR>" },
    { '[',
      "<cmd>lua vim.diagnostic.goto_prev({float = false})<CR><cmd>lua vim.diagnostic.open_float(nil, { border = 'rounded', scope = 'cursor',  focusable = false })<CR>" },
    { '<C-Space>',
      "<cmd>Lspsaga diagnostic_jump_next<CR>", { exit = true } },
  }
})
Hydra({
  name = 'Linter',
  mode = 'n',
  body = '[a',
  config = {
    hint = false,
    invoke_on_body = true,
    on_enter = function()
      diagnostic.goto_prev({ float = false })
      diagnostic.open_float(nil, { border = 'rounded', scope = 'cursor', focusable = false })
    end
  },
  heads = {
    { ']',
      "<cmd>lua vim.diagnostic.goto_next({float = false})<CR><cmd>lua vim.diagnostic.open_float(nil, { border = 'rounded', scope = 'cursor',  focusable = false })<CR>" },
    { '[',
      "<cmd>lua vim.diagnostic.goto_prev({float = false})<CR><cmd>lua vim.diagnostic.open_float(nil, { border = 'rounded', scope = 'cursor',  focusable = false })<CR>" },
    { '<C-Space>',
      "<cmd>Lspsaga diagnostic_jump_prev<CR>", { exit = true } },
  }
})
