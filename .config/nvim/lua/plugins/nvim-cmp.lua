-- Set completeopt to have a better completion experience
vim.o.completeopt = "menuone,noselect"

-- luasnip setup
local luasnip = require("luasnip")
require("snippets")
vim.api.nvim_set_keymap("i", "<M-j>", "<Plug>luasnip-jump-next", {})
vim.api.nvim_set_keymap("s", "<M-j>", "<Plug>luasnip-jump-next", {})
vim.api.nvim_set_keymap("i", "<M-k>", "<Plug>luasnip-jump-prev", {})
vim.api.nvim_set_keymap("s", "<M-k>", "<Plug>luasnip-jump-prev", {})
vim.api.nvim_set_keymap("i", "<M-e>", "<Plug>luasnip-next-choice", {})
vim.api.nvim_set_keymap("s", "<M-e>", "<Plug>luasnip-next-choice", {})
vim.api.nvim_set_keymap("s", "<C-Space>", "<Plug>luasnip-expand-or-jump", {})
vim.api.nvim_set_keymap("s", "p", "p", { noremap = true })

-- nvim-cmp utils
local check_back_space = function()
  local col = vim.fn.col(".") - 1
  return col == 0 or vim.fn.getline("."):sub(col, col):match("%s")
end

-- nvim-cmp setup
local cmp = require("cmp")
cmp.setup({
  formatting = {
    format = function(entry, vim_item)
      vim_item.kind = require("lspkind").presets.default[vim_item.kind]
      -- set a name for each source
      vim_item.menu = ({
        buffer = "[B]",
        nvim_lsp = "[L]",
        luasnip = "[S]",
        cmp_tabnine = "[T]",
        nvim_lua = "[Lu]",
        rg = "[R]",
        tmux = "[M]",
        copilot = "[C]",
        nvim_lsp_document_symbol = "[D]",
        cmdline_history = "[H]",
      })[entry.source.name]
      local label = vim_item.abbr
      local truncated_label = vim.fn.strcharpart(label, 0, 80)
      if truncated_label ~= label then
        vim_item.abbr = truncated_label .. "…"
      end
      return vim_item
    end,
  },
  snippet = {
    expand = function(args)
      require("luasnip").lsp_expand(args.body)
    end,
  },
  mapping = {
    ["<C-p>"] = function()
      if cmp.visible() then
        if cmp.core.view.custom_entries_view:is_direction_top_down() then
          cmp.select_prev_item({ behavior = cmp.SelectBehavior.Select })
        else
          cmp.select_next_item({ behavior = cmp.SelectBehavior.Select })
        end
      else
        vim.fn.feedkeys(vim.api.nvim_replace_termcodes("<C-g>U<Up>", true, true, true), "n")
      end
    end,
    ["<C-n>"] = function()
      if cmp.visible() then
        if cmp.core.view.custom_entries_view:is_direction_top_down() then
          cmp.select_next_item({ behavior = cmp.SelectBehavior.Select })
        else
          cmp.select_prev_item({ behavior = cmp.SelectBehavior.Select })
        end
      else
        vim.fn.feedkeys(vim.api.nvim_replace_termcodes("<C-g>U<Down>", true, true, true), "n")
      end
    end,
    ["<C-e>"] = function()
      cmp.abort()
      vim.fn.feedkeys(vim.api.nvim_replace_termcodes("<C-g>U<C-o>$<C-g>U<Right>", true, true, true), "n")
    end,
    ["<M-d>"] = cmp.mapping.scroll_docs(-4),
    ["<M-u>"] = cmp.mapping.scroll_docs(4),
    ["<CR>"] = function()
      if cmp.visible() then
        local option = { behavior = cmp.ConfirmBehavior.Insert, select = true }
        cmp.confirm(option)
      else
        vim.fn.feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, true, true), "n")
      end
    end,
    ["<C-Space>"] = function()
      if not cmp.visible() then
        if luasnip.expand_or_jumpable() then
          vim.fn.feedkeys(vim.api.nvim_replace_termcodes("<Plug>luasnip-expand-or-jump", true, true, true), "")
        else
          cmp.complete()
        end
      elseif cmp.visible() then
        local option = { behavior = cmp.ConfirmBehavior.Replace, select = true }
        cmp.confirm(option)
      end
    end,
  },
  experimental = {
    ghost_text = true,
    hl_group = "LineNr"
  },
  sources = cmp.config.sources({
    { name = "nvim_lsp", max_item_count = 20 },
    { name = "luasnip", max_item_count = 20 },
    { name = "copilot" },
    { name = "buffer", max_item_count = 3 },
    -- { name = "cmp_tabnine" },
    { name = "rg", keyword_length = 3 },
    { name = "path" },
    -- {
    --   name = "tmux",
    --   keyword_length = 3,
    --   max_item_count = 5,
    --   -- opts = { all_panes = true } --ちょっと遅い
    -- },
  }),
  view = {
    entries = {
      selection_order = "bottom_up",
    },
  },
  window = {
    documentation = {
      border = { "┌", "─", "┐", "│", "┘", "─", "└", "│" },
      winhighlight = "Normal:CmpPmenu,FloatBorder:LspInlayHint,CursorLine:PmenuSel,Search:None",
    },
    completion = {
      -- border = { "┌", "─", "┐", "│", "┘", "─", "└", "│" },
      -- winhighlight = "Normal:CmpPmenu,FloatBorder:CmpPmenuBorder,CursorLine:PmenuSel,Search:None",
      -- col_offset = 0,
      -- side_padding = 0,
    },
  },
  sorting = {
    comparators = {
      cmp.config.compare.exact,
      cmp.config.compare.score,
      cmp.config.compare.kind,
      cmp.config.compare.locality,
      cmp.config.compare.scopes,
      cmp.config.compare.recently_used,
      cmp.config.compare.length,
      cmp.config.compare.offset,
      cmp.config.compare.sort_text,
      cmp.config.compare.order,
    },
  },
  preselect = cmp.PreselectMode.Item,
})

local cmdline_mapping = cmp.mapping.preset.cmdline()

cmdline_mapping["<M-p>"] = {
  c = function()
    vim.fn.feedkeys(vim.api.nvim_replace_termcodes("<C-p>", true, true, true), "n")
  end,
}
cmdline_mapping["<M-n>"] = {
  c = function()
    vim.fn.feedkeys(vim.api.nvim_replace_termcodes("<C-n>", true, true, true), "n")
  end,
}
-- Use buffer source for `/` (if you enabled `native_menu`, this won't work anymore).
cmp.setup.cmdline({ "/", "?" }, {
  mapping = cmdline_mapping,
  sources = cmp.config.sources({
    -- { name = 'fuzzy_buffer' },
    { name = "buffer" },
  }, {
    { name = "nvim_lsp_document_symbol" },
    { name = "cmdline_history" },
    -- { name = 'buffer-lines' },
  }),
})

-- Use cmdline & path source for ':' (if you enabled `native_menu`, this won't work anymore).
cmp.setup.cmdline(":", {
  mapping = cmdline_mapping,
  sources = cmp.config.sources({
    { name = "cmdline" },
    { name = "path" },
  }, {
    { name = "cmdline_history" },
  }),
})
