-- Set completeopt to have a better completion experience
vim.o.completeopt = 'menuone,noselect'

-- luasnip setup
local luasnip = require 'luasnip'
require("snippets")
vim.api.nvim_set_keymap("i", "<M-j>", "<Plug>luasnip-jump-next", {})
vim.api.nvim_set_keymap("s", "<M-j>", "<Plug>luasnip-jump-next", {})
vim.api.nvim_set_keymap("i", "<M-k>", "<Plug>luasnip-jump-prev", {})
vim.api.nvim_set_keymap("s", "<M-k>", "<Plug>luasnip-jump-prev", {})
vim.api.nvim_set_keymap("i", "<M-e>", "<Plug>luasnip-next-choice", {})
vim.api.nvim_set_keymap("s", "<M-e>", "<Plug>luasnip-next-choice", {})
vim.api.nvim_set_keymap('s', '<C-Space>', '<Plug>luasnip-expand-or-jump', {})
vim.api.nvim_set_keymap('s', 'p', 'p', { noremap = true })

-- nvim-cmp utils
local check_back_space = function()
  local col = vim.fn.col('.') - 1
  return col == 0 or vim.fn.getline('.'):sub(col, col):match('%s')
end

-- nvim-cmp setup
local cmp = require 'cmp'
cmp.setup {
  formatting = {
    format = function(entry, vim_item)
      -- vim_item.kind = require('lspkind').presets.default[vim_item.kind]
      -- set a name for each source
      vim_item.menu = ({
        buffer = "[B]",
        nvim_lsp = "[L]",
        luasnip = "[S]",
        cmp_tabnine = "[T]",
        nvim_lua = "[Lu]",
        tmux = "[M]",
      })[entry.source.name]
      return vim_item
    end,
  },
  snippet = {
    expand = function(args)
      require('luasnip').lsp_expand(args.body)
    end,
  },
  mapping = {
    ['<C-p>'] = function()
      if cmp.visible() then
        cmp.select_prev_item()
      else
        vim.fn.feedkeys(vim.api.nvim_replace_termcodes('<C-g>U<Up>', true, true, true), 'n')
      end
    end,
    ['<C-n>'] = function()
      if cmp.visible() then
        cmp.select_next_item()
      else
        vim.fn.feedkeys(vim.api.nvim_replace_termcodes('<C-g>U<Down>', true, true, true), 'n')
      end
    end,
    ['<M-d>'] = cmp.mapping.scroll_docs(-4),
    ['<M-u>'] = cmp.mapping.scroll_docs(4),
    ['<CR>'] = cmp.mapping.close(),
    ['<C-Space>'] = function()
      if not cmp.visible() then
        if luasnip.expand_or_jumpable() then
          vim.fn.feedkeys(vim.api.nvim_replace_termcodes('<Plug>luasnip-expand-or-jump', true, true, true), '')
        else
          cmp.complete()
        end
      elseif cmp.visible() then
        local option = { behavior = cmp.ConfirmBehavior.Replace, select = true, }
        cmp.confirm(option)
      end
    end,
  },
  experimental = {
    ghost_text = true
  },
  sources = {
    { name = 'nvim_lsp' },
    { name = 'luasnip' },
    { name = 'cmp_tabnine' },
    { name = 'path' },
    { name = 'tmux',
      keyword_length = 3,
      max_item_count = 5,
      -- opts = { all_panes = true } --ちょっと遅い
    },
  },
  sorting = {
    comparators = {
      cmp.config.compare.offset,
      cmp.config.compare.exact,
      cmp.config.compare.score,
      cmp.config.compare.kind,
      cmp.config.compare.sort_text,
      cmp.config.compare.length,
      cmp.config.compare.order,
    }
  },
  preselect = cmp.PreselectMode.Item
}

require('cmp.config').get().experimental.ghost_text.hl_group = 'LineNr'
