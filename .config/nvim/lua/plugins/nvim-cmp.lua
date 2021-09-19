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

-- nvim-cmp utils
local check_back_space = function()
  local col = vim.fn.col('.') - 1
  return col == 0 or vim.fn.getline('.'):sub(col, col):match('%s')
end

-- nvim-cmp setup
local cmp = require 'cmp'
local core = require 'cmp.core'
cmp.setup {
  formatting = {
    format = function(entry, vim_item)
      vim_item.kind = require('lspkind').presets.default[vim_item.kind]
      -- set a name for each source
      vim_item.menu = ({
        buffer = "[B]",
        nvim_lsp = "[L]",
        luasnip = "[S]",
        cmp_tabnine = "[T]",
        nvim_lua = "[Lu]",
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
    ['<C-p>'] = function(fallback)
      if vim.fn.pumvisible() == 1 then
        cmp.mapping.select_prev_item()
      else
        vim.fn.feedkeys(vim.api.nvim_replace_termcodes('<C-g>U<Up>', true, true, true), 'n')
      end
    end,
    ['<C-n>'] = function(fallback)
      if vim.fn.pumvisible() == 1 then
        cmp.mapping.select_next_item()
      else
        vim.fn.feedkeys(vim.api.nvim_replace_termcodes('<C-g>U<Down>', true, true, true), 'n')
      end
    end,
    ['<M-d>'] = cmp.mapping.scroll_docs(-4),
    ['<M-u>'] = cmp.mapping.scroll_docs(4),
    ['<CR>'] = cmp.mapping.close(),
    ['<C-Space>'] = function()
      if vim.fn.pumvisible() == 0 then
        if luasnip.expand_or_jumpable() then
          vim.fn.feedkeys(vim.api.nvim_replace_termcodes('<Plug>luasnip-expand-or-jump', true, true, true), '')
        else
          core.complete(core.get_context({ reason = cmp.ContextReason.Manual }))
          return true
        end
      elseif vim.fn.pumvisible() == 1 then
        local option = { behavior = cmp.ConfirmBehavior.Replace, select = true, }
        local e = core.menu:get_selected_entry() or (option.select and core.menu:get_first_entry() or nil)
        if e then
          core.confirm(e, {
            behavior = option.behavior,
          }, function()
            core.complete(core.get_context({ reason = cmp.ContextReason.TriggerOnly }))
          end)
          return true
        else
          return false
        end
      end
    end,
  },
  sources = {
    { name = 'nvim_lsp' },
    { name = 'luasnip' },
    { name = 'nvim_lua' },
    { name = 'cmp_tabnine' },
    { name = 'path' },
  },
}
