return {
  { 'mikavilpas/blink-ripgrep.nvim', event = 'InsertEnter' },
  { 'rafamadriz/friendly-snippets', event = 'InsertEnter' },
  { 'dmitmel/cmp-cmdline-history', event = 'CmdlineEnter' },
  { 'Kaiser-Yang/blink-cmp-avante', ft = 'AvanteInput' },
  { 'mgalliou/blink-cmp-tmux', ft = 'lazyagent' },
  { 'fang2hou/blink-copilot', event = 'InsertEnter' },
  { 'hrsh7th/cmp-nvim-lsp-document-symbol', event = 'CmdlineEnter' },
  { 'saghen/blink.lib', event = { 'InsertEnter', 'CmdlineEnter' } },
  { 'copilotlsp-nvim/copilot-lsp', lazy = true,
    opts = { nes = { distance_threshold = 100, clear_on_large_distance = false, } }
  },
  {
    'saghen/blink.cmp',
    dependencies = { 'blink-extension' },
    event = { 'InsertEnter', 'CmdlineEnter' },
    build = function()
      require('blink.cmp').build():pwait()
    end,
    config = function(_, opts)
      local cmp = require('blink.cmp')
      cmp.setup(opts)

      local orig_is_enabled = cmp.is_enabled
      cmp.is_enabled = function()
        if vim.api.nvim_get_mode().mode == 't' and vim.b.is_fzf_lua_picker then
          return false
        end
        return orig_is_enabled()
      end
    end,
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
        sources = {
          default = function()
            local type = vim.fn.getcmdtype()
            if type == '/' or type == '?' then return { 'document_symbol', 'buffer' } end
            if type == ':' or type == '@' then return { 'cmdline', 'history' } end
            return {}
          end,
        },
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
            preselect = false,
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
        default = { 'lsp', 'copilot', 'lazydev', 'lsp', 'path', 'snippets', 'buffer', 'ripgrep', 'japanese' },
        per_filetype = {
          AvanteInput = { 'avante', 'buffer', 'ripgrep', 'japanese' },
          sql = { 'connector', 'buffer', 'snippets'  },
          text = { 'buffer', 'ripgrep', 'japanese' },
          markdown = { 'buffer', 'ripgrep', 'japanese', 'snippets' },
          lazyagent = { 'buffer', 'ripgrep', 'japanese', 'tmux', 'lazyagent' },
          php = { 'lsp', 'copilot', 'lazydev', 'laravel', 'path', 'snippets', 'buffer', 'ripgrep', 'japanese'  },
        },
        providers = {
          lazyagent = {
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
            module = "blink_extension.completion.buffer_ascii",
            score_offset = -5,
            should_show_items = function(ctx)
              return not require("blink_extension.features.completion").is_japanese_completion_context(ctx)
            end,
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
              items = require("blink_extension.features.completion").filter_ascii_completion_items(items)
              for _, item in ipairs(items) do
                item.kind_name = 'text'
              end
              return items
            end,
            should_show_items = function(ctx, items)
              return not require("blink_extension.features.completion").is_japanese_completion_context(ctx) and #items > 0
            end,
          },
          japanese = {
            module = "blink_extension.completion.japanese",
            name = "[J]",
            async = true,
            score_offset = -18,
            min_keyword_length = 2,
            opts = {
              min_keyword_length = 2,
              max_items = 50,
              max_filesize = "1M",
              max_line_matches = 20,
              project_root_marker = ".git",
              project_root_fallback = true,
              search_casing = "--ignore-case",
            },
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
          tmux = {
            module = "blink-cmp-tmux",
            name = "tmux",
            score_offset = -15,
          },
          connector = {
            module = "connector.blink",
            name = "[CO]",
            async = true,
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
