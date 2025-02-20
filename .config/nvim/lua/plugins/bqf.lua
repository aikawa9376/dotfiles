local setting = require('bqf.config')
setting.preview.border_chars = {'│', '│', '─', '─', '┌', '┐', '└', '┘', '█'}
vim.cmd([[
    hi link BqfPreviewFloat NormalFloat
    hi BqfPreviewBorder ctermbg=None guibg=#002b36 guifg=#839496
    hi BqfPreviewTitle ctermbg=None guibg=#002b36 guifg=#839496
]])
