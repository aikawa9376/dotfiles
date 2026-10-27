local code_padding = { language_pad = 1, left_pad = 1, right_pad = 1, min_width = 40 }
local file_types = { 'markdown', 'blink-cmp-documentation', 'Avante', 'fzf', 'lazyagent', 'lazyagent_acp', 'gitpr', 'gitissue' }

return {
  "aikawa9376/inkstone.nvim",
  main = "inkstone",
  ft = file_types,
  opts = {
    -- restart_highlighter = true,
    anti_conceal = {
      enabled = false,
    },
    file_types = file_types,
    ignore = function(buf)
      return (vim.bo[buf].filetype == 'gitpr' or vim.bo[buf].filetype == 'gitissue') and vim.b[buf].git_pr_markdown_ranges == nil
    end,
    heading = {
      sign = false,
      position = "inline",
    },
    code = {
      sign = false,
      position = "right",
      width = "block",
      language_pad = code_padding.language_pad,
      left_pad = code_padding.left_pad,
      right_pad = code_padding.right_pad,
      min_width = code_padding.min_width,
      above = '▄',
      below = '▀',
      disable_background = { 'diff' },
    },
    pipe_table = {
      cell = 'trimmed',
      wrap = true,
      japanese = { enabled = true, budoux = true },
    },
    checkbox = {
      enabled = true,
      render_modes = false,
      unchecked = {
        icon = '󰄱 ',
        highlight = 'InkstoneUnchecked',
        scope_highlight = nil,
      },
      checked = {
        icon = '󰱒 ',
        highlight = 'InkstoneChecked',
        scope_highlight = nil,
      },
      custom = {
        todo = { raw = '[-]', rendered = ' ', highlight = 'InkstoneTodo', scope_highlight = nil },
        unchecked = { raw = '[ ]', rendered = '󰄱 ', highlight = 'InkstoneUnchecked', scope_highlight = nil },
        checked = { raw = '[x]', rendered = '󰱒 ', highlight = 'InkstoneChecked', scope_highlight = nil },
      },
    },
    bullet = {
      render_modes = false,
      icons = { '' , '', '', '' },
    },
    completions = {
      lsp = { enabled = true },
      blink = { enabled = true },
    },
    custom_handlers = {
      markdown = {
        parse = function(ctx)
          local bufnr = ctx and ctx.buf or nil
          local ft = bufnr and vim.bo[bufnr].filetype or ""
          if ft == 'gitpr' or ft == 'gitissue' then return require('git.features.pr_markdown').parse(ctx) end
          if ft == "lazyagent" or ft == "lazyagent_acp" then
            return require("lazyagent.render_markdown").parse(ctx)
          end
          local marks = require("inkstone.handler.markdown").parse(ctx)
          local ok, properties = pcall(require, "obsidian_extension.features.properties")
          if ok and type(properties.filter_render_marks) == "function" then
            return properties.filter_render_marks(bufnr, marks)
          end
          return marks
        end,
      },
    },
    overrides = {
      buftype = {
        nofile = {
          -- LSP floats measure buffer text before virtual padding is rendered.
          code = {
            language_pad = 0,
            left_pad = 0,
            right_pad = 0,
            min_width = 0,
          },
        },
      },
      filetype = {
        ['blink-cmp-documentation'] = {
          -- Blink already delays item updates; render each completed draw immediately.
          debounce = 0,
          win_options = {
            concealcursor = { rendered = 'nvic' },
          },
        },
        -- Preserve padding in the other scratch views that also use nofile buffers.
        Avante = { code = code_padding },
        fzf = { code = code_padding },
        gitissue = {
          sign = { enabled = false },
          heading = { sign = false },
          code = vim.tbl_extend('force', code_padding, { sign = false }),
        },
        gitpr = {
          sign = { enabled = false },
          heading = { sign = false },
          code = vim.tbl_extend('force', code_padding, { sign = false }),
        },
        lazyagent = {
          code = code_padding,
          debounce = 300,
          render_modes = { 'n', 't' },
        },
        lazyagent_acp = {
          code = code_padding,
          debounce = 300,
          render_modes = { 'n', 't' },
        },
      },
    },
  },
  init = function ()
    vim.g.markdown_renderer = "inkstone"
    vim.treesitter.language.register('markdown', file_types)

    local function set_highlights()
      -- H1 ～ H6 のフォアグラウンド（文字色）と背景色の設定
      vim.api.nvim_set_hl(0, "@markup.heading.1.markdown", { fg = "#61afef", bg = "NONE", bold = true })
      vim.api.nvim_set_hl(0, "@markup.heading.2.markdown", { fg = "#e5c07b", bg = "NONE", bold = true })
      vim.api.nvim_set_hl(0, "@markup.heading.3.markdown", { fg = "#98c379", bg = "NONE", bold = true })
      vim.api.nvim_set_hl(0, "@markup.heading.4.markdown", { fg = "#56b6c2", bg = "NONE", bold = true })
      vim.api.nvim_set_hl(0, "@markup.heading.5.markdown", { fg = "#c678dd", bg = "NONE", bold = true })
      vim.api.nvim_set_hl(0, "@markup.heading.6.markdown", { fg = "#abb2bf", bg = "NONE", bold = true })

      -- H1 ～ H6 の背景色専用設定
      vim.api.nvim_set_hl(0, "InkstoneH1Bg", { bg = "NONE", bold = true })
      vim.api.nvim_set_hl(0, "InkstoneH2Bg", { bg = "NONE", bold = true })
      vim.api.nvim_set_hl(0, "InkstoneH3Bg", { bg = "NONE", bold = true })
      vim.api.nvim_set_hl(0, "InkstoneH4Bg", { bg = "NONE", bold = true })
      vim.api.nvim_set_hl(0, "InkstoneH5Bg", { bg = "NONE", bold = true })
      vim.api.nvim_set_hl(0, "InkstoneH6Bg", { bg = "NONE", bold = true })

      -- InkstoneQuote1 ～ Quote6: follow heading colors (参考: heading)
      vim.api.nvim_set_hl(0, "InkstoneQuote1", { fg = "#61afef", bg = "NONE", italic = true })
      vim.api.nvim_set_hl(0, "InkstoneQuote2", { fg = "#e5c07b", bg = "NONE", italic = true })
      vim.api.nvim_set_hl(0, "InkstoneQuote3", { fg = "#98c379", bg = "NONE", italic = true })
      vim.api.nvim_set_hl(0, "InkstoneQuote4", { fg = "#56b6c2", bg = "NONE", italic = true })
      vim.api.nvim_set_hl(0, "InkstoneQuote5", { fg = "#c678dd", bg = "NONE", italic = true })
      vim.api.nvim_set_hl(0, "InkstoneQuote6", { fg = "#abb2bf", bg = "NONE", italic = true })

      vim.api.nvim_set_hl(0, "InkstoneUnchecked", { fg = "#abb2bf", bg = "NONE", bold = true })
      vim.api.nvim_set_hl(0, "InkstoneChecked", { fg = "#98c379", bg = "NONE", bold = true })

      vim.api.nvim_set_hl(0, "InkstoneBullet", { fg = "#98c379" })

      vim.api.nvim_set_hl(0, "InkstoneCode", { bg = "#073642" })
    end
    set_highlights()
    vim.api.nvim_create_autocmd("ColorScheme", {
      group = vim.api.nvim_create_augroup("InkstoneUserHighlights", { clear = true }),
      callback = set_highlights,
    })
  end
}
