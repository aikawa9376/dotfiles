return {
  { 'mikavilpas/blink-ripgrep.nvim', event = 'InsertEnter' },
  { 'rafamadriz/friendly-snippets', event = 'InsertEnter' },
  { 'dmitmel/cmp-cmdline-history', event = 'CmdlineEnter' },
  { 'Kaiser-Yang/blink-cmp-avante', ft = 'AvanteInput' },
  { 'fang2hou/blink-copilot', event = 'InsertEnter' },
  { 'hrsh7th/cmp-nvim-lsp-document-symbol', event = 'CmdlineEnter' },
  { 'copilotlsp-nvim/copilot-lsp', lazy = true,
    opts = { nes = { distance_threshold = 100, clear_on_large_distance = false, } }
  },
  {
    'saghen/blink.cmp',
    event = { 'InsertEnter', 'CmdlineEnter' },
    build = 'cargo build --release',
    -- version = '*',
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
          ['<CR>'] = { 'accept_and_enter', 'fallback' },
          ['<C-space>'] = {
            function(cmp)
              if not cmp.is_visible() then
                return cmp.show()
              else
                return cmp.select_accept_and_enter()
              end
            end,
            'fallback',
          },
          ['<C-c>'] = { 'cancel', 'fallback' },
          ['<C-e>'] = false,
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
        },
        ghost_text = {
          enabled = true,
        },
        menu = {
          border = 'none',
          min_width = 20,
          -- TODO 逆方向モード実装まで
          max_height = 10,
          order = { n = 'bottom_up', s = 'top_down' },
          draw = {
            columns = {
              { "kind_icon" },
              { "label", gap = 1 },
              { "kind" },
              { "source_name" },
            },
            components = {
              label = {
                width = { fill = true, max = 35 },
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
        default = { 'lsp', 'copilot', 'lazydev', 'lsp', 'path', 'snippets', 'buffer', 'ripgrep' },
        per_filetype = {
          AvanteInput = { 'avante', 'buffer', 'ripgrep' },
          sql = { 'buffer', 'snippets' },
          text = { 'buffer', 'ripgrep' },
          markdown = { 'buffer', 'ripgrep', 'snippets', 'lazyagent' },
          php = { 'lsp', 'copilot', 'lazydev', 'laravel', 'path', 'snippets', 'buffer', 'ripgrep'  },
        },
        providers = {
          ["lazyagent"] = {
            name = '[SA]',
            module = 'lazyagent.completion.blink',
          },
          lsp = {
            name = "[L]",
            fallbacks = {}
          },
          snippets = {
            name = "[S]",
          },
          path = {
            name = "[S]"
          },
          buffer = {
            name = "[B]",
            score_offset = -5,
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
              backend = {
                context_size = 5,
                max_filesize = "1M",
                project_root_fallback = true,
                search_casing = "--ignore-case",
              },
              prefix_min_len = 3,
              project_root_marker = ".git",
            },
            transform_items = function(_, items)
              for _, item in ipairs(items) do
                item.kind_name = 'text'
              end
              return items
            end,
          },
          history = {
            name = '[H]',
            score_offset = -20,
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
            async = true,
            opts = {
              max_completions = 3,  -- Override global max_completions
            }
          },
          laravel = {
            name = "[L]",
            score_offset = -2005,
            module = "laravel.blink_source",
          },
        },
      },
      fuzzy = {
        implementation = "prefer_rust_with_warning",
        sorts = {
          function (a, b)
            if require"blink.cmp".get_context().get_keyword() == "" then
              return nil
            end
            if a.kind_name == "Copilot" and b.client_name ~= nil then
              return false
            end
            if a.client_name ~= nil and b.kind_name == "Copilot" then
              return true
            end
          end,
          "score",
          "sort_text",
          -- "kind",
          -- "label",
          -- "exact",
        }
      },
      snippets = { preset = 'luasnip' },
      signature = {
        enabled = true,
        trigger = {
          enabled = true,
          show_on_insert = true
        },
      }
    },
    opts_extend = { "sources.default" }
  }
}
