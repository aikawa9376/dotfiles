return {
  "kevinhwang91/nvim-bqf",
  ft = "qf",
  config = function ()
    local setting = require('bqf.config')
    setting.preview.border = 'single',
    vim.cmd([[
        hi link BqfPreviewFloat NormalFloat
        hi BqfPreviewBorder ctermbg=None guibg=#002b36 guifg=#839496
        hi BqfPreviewTitle ctermbg=None guibg=#002b36 guifg=#839496
    ]])
  end
}
