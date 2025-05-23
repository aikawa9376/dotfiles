return {
  { "hrsh7th/cmp-nvim-lsp", lazy = true },
  { "hrsh7th/cmp-buffer", event = "InsertEnter" },
  { "hrsh7th/cmp-path", event = "InsertEnter" },
  { "hrsh7th/cmp-nvim-lsp-document-symbol", event = "InsertEnter" },
  { "andersevenrud/cmp-tmux", event = "InsertEnter" },
  { "hrsh7th/cmp-cmdline", event = "CmdlineEnter" },
  { "dmitmel/cmp-cmdline-history", event = "CmdlineEnter" },
  { "zbirenbaum/copilot-cmp", event = "InsertEnter" },
  { "saadparwaiz1/cmp_luasnip", event = "InsertEnter" },
  { "lukas-reineke/cmp-rg", event = "InsertEnter" },
  { "rafamadriz/friendly-snippets", event = "InsertEnter" },
  { "zbirenbaum/copilot.lua", config = true },
  { "zbirenbaum/copilot-cmp", config = true },
  {
    "hrsh7th/nvim-cmp",
    event = { "InsertEnter", "CmdlineEnter" },
    config = function ()
      -- nvim-cmp setup
      local cmp = require("cmp")
      local luasnip = require("luasnip")
      cmp.setup({
        formatting = {
          format = function(entry, vim_item)
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
            local icon = require("lspkind").presets.default[vim_item.kind] or ""
            vim_item.abbr = icon .. " " .. vim_item.abbr
            return vim_item
          end,
        },
        snippet = {
          expand = function(args)
            luasnip.lsp_expand(args.body)
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
              local option = { behavior = cmp.ConfirmBehavior.Replace, select = true }
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
              local option = { behavior = cmp.ConfirmBehavior.Insert, select = true }
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
          {
            name = "tmux",
            keyword_length = 3,
            max_item_count = 5,
            -- opts = { all_panes = true } --ちょっと遅い
          },
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
        performance = {
          debounce = 0, -- default is 60ms
          throttle = 0, -- default is 30ms
        },
      })

      local cmdline_mapping = cmp.mapping.preset.cmdline({
        ["<M-p>"] = {
          c = function()
            vim.fn.feedkeys(vim.api.nvim_replace_termcodes("<C-p>", true, true, true), "n")
          end,
        },
        ["<M-n>"] = {
          c = function()
            vim.fn.feedkeys(vim.api.nvim_replace_termcodes("<C-n>", true, true, true), "n")
          end,
        },
        ["<C-Space>"] = {
          c = function(fallback)
            if cmp.visible() then
              cmp.confirm({ select = true })
            else
              fallback()
            end
          end,
        },
        -- ["<C-j>"] = {
        --   c = function()
        --     cmp.select_next_item { behavior = cmp.SelectBehavior.Insert }
        --   end,
        -- },
        -- ["<C-k>"] = {
        --   c = function()
        --     cmp.select_prev_item { behavior = cmp.SelectBehavior.Insert }
        --   end,
        -- },
      })

      -- Use buffer source for `/` (if you enabled `native_menu`, this won't work anymore).
      cmp.setup.cmdline({ "/", "?" }, {
        mapping = cmdline_mapping,
        sources = cmp.config.sources(
          {
            { name = "buffer" },
          },
          {
            { name = "nvim_lsp_document_symbol" },
            { name = "cmdline_history" },
          }
        ),
      })

      -- Use cmdline & path source for ':' (if you enabled `native_menu`, this won't work anymore).
      cmp.setup.cmdline(":", {
        mapping = cmdline_mapping,
        completion = {
          completeopt = 'menu,menuone,noselect',
        },
        sources = cmp.config.sources(
          {
            { name = "cmdline" },
            { name = "path" },
          },
          {
            { name = "cmdline_history" },
          }),
        })
    end
  }
}
