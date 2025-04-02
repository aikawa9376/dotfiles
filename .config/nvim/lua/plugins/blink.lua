return {
  { 'mikavilpas/blink-ripgrep.nvim', event = 'InsertEnter' },
  { 'rafamadriz/friendly-snippets', event = 'InsertEnter' },
  { 'dmitmel/cmp-cmdline-history', event = 'CmdlineEnter' },
  { 'Kaiser-Yang/blink-cmp-avante', ft = 'AvanteInput' },
  { 'fang2hou/blink-copilot', event = 'InsertEnter' },
  { 'zbirenbaum/copilot.lua', event = 'InsertEnter', config = true },
  { 'hrsh7th/cmp-nvim-lsp-document-symbol', event = 'CmdlineEnter' },
  {
    'saghen/blink.cmp',
    event = { 'InsertEnter', 'CmdlineEnter' },
    build = 'cargo build --release',
    ---@module 'blink.cmp'
    ---@type blink.cmp.Config
    opts = {
      cmdline = {
        enabled = true,
        completion = {
          list = {
            selection = {
              preselect = false,
              auto_insert = true,
            }
          },
          menu = { auto_show = true },
        },
        keymap = {
          ['<C-space>'] = {
            function(cmp)
              if not cmp.is_visible() then
                return cmp.show()
              else
                return cmp.select_and_accept()
              end
            end,
            'fallback',
          },
          ['<C-c>'] = { 'cancel', 'fallback' },
          ['<C-e>'] = { 'fallback' },
        },
        ---@diagnostic disable-next-line: assign-type-mismatch
        sources = function()
          local type = vim.fn.getcmdtype()
          if type == '/' or type == '?' then return { 'document_symbol', 'buffer' } end
          if type == ':' or type == '@' then return { 'cmdline', 'history' } end
          return {}
        end,
      },
      keymap = {
        preset = 'none',
        ['<C-space>'] = {
          function(cmp)
            if not cmp.is_visible() then
              if require'luasnip'.expand_or_jumpable() then
                return vim.fn.feedkeys(
                  vim.api.nvim_replace_termcodes(
                    "<Plug>luasnip-expand-or-jump",
                    true,
                    true,
                    true
                  ),
                  "n"
                )
              else
                return cmp.show()
              end
            else
              return cmp.select_and_accept()
            end
          end,
          'fallback',
        },
        ['<CR>'] = {
          function(cmp)
            if cmp.is_visible() then
              return cmp.accept()
            else
              return false
            end
          end,
          'fallback',
        },
        -- ['<Tab>'] = { 'snippet_forward', 'fallback' },
        ['<C-c>'] = { 'cancel', 'fallback' },
        ['<C-p>'] = {
          function (cmp)
            if cmp.is_visible() then
              return cmp.select_prev()
            else
              return vim.fn.feedkeys(
                vim.api.nvim_replace_termcodes(
                  "<C-g>U<Up>",
                  true,
                  true,
                  true
                ),
                "n"
              )
            end
          end,
          'fallback'
        },
        ['<C-n>'] = {
          function (cmp)
            if cmp.is_visible() then
              return cmp.select_next()
            else
              return vim.fn.feedkeys(
                vim.api.nvim_replace_termcodes(
                  "<C-g>U<DOWN>",
                  true,
                  true,
                  true
                ),
                "n"
              )
            end
          end,
          'fallback'
        },
      },

      appearance = {
        -- 'mono' (default) for 'Nerd Font Mono' or 'normal' for 'Nerd Font'
        -- Adjusts spacing to ensure icons are aligned
        nerd_font_variant = 'mono'
      },

      -- (Default) Only show the documentation popup when manually triggered
      completion = {
        list = {
          selection = {
            preselect = true,
            auto_insert = false,
          }
        },
        documentation = {
          auto_show = true,
          auto_show_delay_ms = 300,
          window = {
            border = 'rounded'
          }
        },
        ghost_text = {
          enabled = true,
        },
        menu = {
          min_width = 20,
          max_height = 10,
          draw = {
            columns = {
              { "kind_icon" },
              { "label", gap = 1 },
              { "kind" },
              { "source_name" },
            },
            components = {
              label = {
                text = function(ctx)
                  return require("colorful-menu").blink_components_text(ctx)
                end,
                highlight = function(ctx)
                  return require("colorful-menu").blink_components_highlight(ctx)
                end,
              },
            },
          },
        }
      },
      sources = {
        default = { 'copilot', 'lazydev', 'lsp', 'path', 'snippets', 'buffer', 'ripgrep' },
        per_filetype = {
          AvanteInput = { 'avante', 'buffer', 'ripgrep' },
        },
        providers = {
          lsp = {
            name = "[L]",
            fallbacks = {}
          },
          snippets = {
            name = "[S]"
          },
          path = {
            name = "[S]"
          },
          buffer = {
            name = "[B]",
            score_offset = -15,
          },
          lazydev = {
            name = "[D]",
            module = "lazydev.integrations.blink",
            -- make lazydev completions top priority (see `:h blink.cmp`)
            score_offset = 100,
          },
          cmdline = {
            name = "[C]"
          },
          ripgrep = {
            module = "blink-ripgrep",
            name = "[R]",
            score_offset = -20,
            ---@module "blink-ripgrep"
            ---@type blink-ripgrep.Options
            opts = {
              prefix_min_len = 3,
              context_size = 5,
              max_filesize = "1M",
              project_root_marker = ".git",
              project_root_fallback = true,
              search_casing = "--ignore-case",
            },
          },
          history = {
            name = '[H]',
            score_offset = -15,
            module = 'blink.compat.source',
            opts = {
              cmp_name = 'cmdline_history'
            }
          },
          document_symbol = {
            name = '[S]',
            score_offset = -15,
            module = 'blink.compat.source',
            opts = {
              cmp_name = 'nvim_lsp_document_symbol'
            }
          },
          avante = {
            module = 'blink-cmp-avante',
            name = '[A]',
          },
          copilot = {
            name = "[C]",
            module = "blink-copilot",
            score_offset = 100,
            async = true,
            opts = {
              max_completions = 3,  -- Override global max_completions
            }
          },
        },
      },
      fuzzy = {
        implementation = "prefer_rust_with_warning",
        sorts = {
          "score",
          "sort_text",
          "kind",
          "label",
          "exact",
        }
      },
      snippets = { preset = 'luasnip' },
      signature = {
        enabled = true,
        trigger = {
          enabled = true,
          show_on_insert = true
        },
        window = {
          border = 'rounded'
        }
      }
    },
    opts_extend = { "sources.default" }
  }
}
