return {
  "MeanderingProgrammer/render-markdown.nvim",
  ft = { 'markdown', 'Avante', 'fzf' },
  opts = {
    anti_conceal = {
      enabled = true,
      -- ignored. Possible keys are:
      --  head_icon, head_background, head_border, code_language, code_background, code_border
      --  dash, bullet, check_icon, check_scope, quote, table_border, callout, link, sign
      ignore = {
        code_background = true,
        sign = true,
      },
    },
    file_types = { 'markdown', 'Avante', 'fzf' },
    heading = {
      sign = false,
      position = "inline",
    },
    code = {
      sign = false,
      position = "right",
      width = "block",
      language_pad = 1,
      left_pad = 1,
      right_pad = 1,
      min_width = 40,
      above = '▄',
      below = '▀',
      disable_background = { 'diff' },
    },
    checkbox = {
      enabled = true,
      render_modes = false,
      position = 'inline',
      unchecked = {
        icon = '󰄱 ',
        highlight = 'RenderMarkdownUnchecked',
        scope_highlight = nil,
      },
      checked = {
        icon = '󰱒 ',
        highlight = 'RenderMarkdownChecked',
        scope_highlight = nil,
      },
      custom = {
        todo = { raw = '[-]', rendered = ' ', highlight = 'RenderMarkdownTodo', scope_highlight = nil },
        unchecked = { raw = '[ ]', rendered = '󰄱 ', highlight = 'RenderMarkdownUnChecked', scope_highlight = nil },
        checked = { raw = '[x]', rendered = '󰱒 ', highlight = 'RenderMarkdownChecked', scope_highlight = nil },
      },
    },
  },
  init = function ()
    -- H1 ～ H6 のフォアグラウンド（文字色）と背景色の設定
    vim.api.nvim_set_hl(0, "@markup.heading.1.markdown", { fg = "#61afef", bg = "NONE", bold = true })
    vim.api.nvim_set_hl(0, "@markup.heading.2.markdown", { fg = "#e5c07b", bg = "NONE", bold = true })
    vim.api.nvim_set_hl(0, "@markup.heading.3.markdown", { fg = "#98c379", bg = "NONE", bold = true })
    vim.api.nvim_set_hl(0, "@markup.heading.4.markdown", { fg = "#56b6c2", bg = "NONE", bold = true })
    vim.api.nvim_set_hl(0, "@markup.heading.5.markdown", { fg = "#c678dd", bg = "NONE", bold = true })
    vim.api.nvim_set_hl(0, "@markup.heading.6.markdown", { fg = "#abb2bf", bg = "NONE", bold = true })

    -- H1 ～ H6 の背景色専用設定
    vim.api.nvim_set_hl(0, "RenderMarkdownH1Bg", { bg = "NONE", bold = true, underline = true })
    vim.api.nvim_set_hl(0, "RenderMarkdownH2Bg", { bg = "NONE", bold = true, underline = true })
    vim.api.nvim_set_hl(0, "RenderMarkdownH3Bg", { bg = "NONE", bold = true })
    vim.api.nvim_set_hl(0, "RenderMarkdownH4Bg", { bg = "NONE", bold = true })
    vim.api.nvim_set_hl(0, "RenderMarkdownH5Bg", { bg = "NONE", bold = true })
    vim.api.nvim_set_hl(0, "RenderMarkdownH6Bg", { bg = "NONE", bold = true })

    vim.api.nvim_set_hl(0, "RenderMarkdownUnchecked", { fg = "#abb2bf", bg = "NONE", bold = true })
    vim.api.nvim_set_hl(0, "RenderMarkdownChecked", { fg = "#98c379", bg = "NONE", bold = true })

    vim.api.nvim_set_hl(0, "RenderMarkdownCode", { bg = "#073642" })
  end
}
