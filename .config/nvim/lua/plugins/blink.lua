return {
  { "mikavilpas/blink-ripgrep.nvim", event = "InsertEnter" },
  { "rafamadriz/friendly-snippets", event = "InsertEnter" },
  {
    'saghen/blink.cmp',
    version = '*', -- バイナリをダウンロードする場合
    event = { "InsertEnter", "CmdlineEnter" },
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
        },
        ---@diagnostic disable-next-line: assign-type-mismatch
        sources = function()
          local type = vim.fn.getcmdtype()
          if type == '/' or type == '?' then return { 'buffer' } end
          if type == ':' or type == '@' then return { 'cmdline' } end
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
            elseif cmp.snippet_active() then
              return cmp.accept()
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
          max_height = 20,
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

      -- Default list of enabled providers defined so that you can extend it
      -- elsewhere in your config, without redefining it, due to `opts_extend`
      sources = {
        default = { 'lazydev', 'lsp', 'path', 'snippets', 'buffer', 'ripgrep'  },
        per_filetype = {},
        providers = {
          lsp = {
            fallbacks = {}
          },
          lazydev = {
            name = "LazyDev",
            module = "lazydev.integrations.blink",
            -- make lazydev completions top priority (see `:h blink.cmp`)
            score_offset = 100,
          },
          ripgrep = {
            module = "blink-ripgrep",
            name = "Ripgrep",
            score_offset = -10,
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
        },
      },
      fuzzy = {
        implementation = "prefer_rust_with_warning",
        sorts = {
          "exact",
          "score",
          "kind",
          "label",
          "sort_text",
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
