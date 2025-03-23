return {
  "airblade/vim-gitgutter",
  event = "VeryLazy",
  keys = {
  { "gm", "<cmd>GitGutterPreviewHunk<CR>", silent = true  },
  { "<Leader>gh", "<cmd>GitGutterStageHunk<CR>", silent = true  },
  { "<Leader>gu", "<cmd>GitGutterUndoHunk<CR>", silent = true  },
  { "zhf", "<cmd>GitGutterFold<CR>", silent = true },
  { "ih", "<Plug>(GitGutterTextObjectInnerPending)", mode = { "o" }, silent = true },
  { "ah", "<Plug>(GitGutterTextObjectOuterPending)", mode = { "o" }, silent = true },
  { "ih", "<Plug>(GitGutterTextObjectInnerVisual)", mode = { "x" }, silent = true },
  { "ah", "<Plug>(GitGutterTextObjectOuterVisual)", mode = { "x" }, silent = true }
  },
  init = function ()
    vim.g.gitgutter_sign_added              = "▕"
    vim.g.gitgutter_sign_modified           = "▕"
    vim.g.gitgutter_sign_removed            = "▕"
    vim.g.gitgutter_sign_modified_removed   = "▕"
    vim.g.gitgutter_sign_removed_first_line = "▕"
    vim.g.gitgutter_grep_command            = 'rg --hidden --follow --glob "!.git/*"'
    vim.g.gitgutter_diff_args               = '-w'
    vim.g.gitgutter_preview_win_floating    = 1
    vim.g.gitgutter_highlight_linenrs       = 0
    vim.g.gitgutter_sign_priority           = 10
  end
}
