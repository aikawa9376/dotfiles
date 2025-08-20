return {
  "lewis6991/gitsigns.nvim",
  event = "BufReadPre",
  keys = {
    { "gm", function () require"gitsigns".preview_hunk() end },
    { "<Leader>ga", function () require"gitsigns".stage_hunk() end },
    {
      "<Leader>ga",
      function () require"gitsigns".stage_hunk({vim.fn.line("v"), vim.fn.line(".")}) end,
      mode = { "x" },
    },
    { "<Leader>gu", function () require"gitsigns".reset_hunk() end },
    { "<Leader>gi", function () require"gitsigns".toggle_current_line_blame() end },
    { "<Leader>gd", function () require"gitsigns".diffthis() end },
    { "ih", function () require"gitsigns".select_hunk() end, mode = { "o", "x" } },
    { "ah", function () require"gitsigns".select_hunk() end, mode = { "o", "x" } },
  },
  opts = {
    signs = {
      add          = { text = '▕' },
      change       = { text = '▕' },
      delete       = { text = '_', show_count = true },
      topdelete    = { text = '‾', show_count = true },
      changedelete = { text = '▕' },
      untracked    = { text = '▕' },
    },
    signs_staged = {
      add          = { text = '▕' },
      change       = { text = '▕' },
      -- delete       = { text = '▕' },
      delete       = { text = '_', show_count = true },
      topdelete    = { text = '‾', show_count = true },
      changedelete = { text = '▕' },
      untracked    = { text = '▕' },
    },
    signs_staged_enable = true,
    signcolumn = true,  -- Toggle with `:Gitsigns toggle_signs`
    numhl      = false, -- Toggle with `:Gitsigns toggle_numhl`
    linehl     = false, -- Toggle with `:Gitsigns toggle_linehl`
    word_diff  = false, -- Toggle with `:Gitsigns toggle_word_diff`
    watch_gitdir = {
      follow_files = true
    },
    diff_opts = {
      ignore_blank_lines = false,
      ignore_whitespace = true,
      ignore_whitespace_change = false,
      ignore_whitespace_change_at_eol = true,
    },
    auto_attach = true,
    attach_to_untracked = false,
    current_line_blame = false, -- Toggle with `:Gitsigns toggle_current_line_blame`
    current_line_blame_opts = {
      virt_text = true,
      virt_text_pos = 'eol', -- 'eol' | 'overlay' | 'right_align'
      delay = 500,
      ignore_whitespace = false,
      virt_text_priority = 100,
      use_focus = true,
    },
    current_line_blame_formatter = '<author>, <author_time:%R> - <summary>',
    sign_priority = 6,
    update_debounce = 100,
    status_formatter = nil, -- Use default
    max_file_length = 40000, -- Disable if file is longer than this (in lines)
    preview_config = {
      -- Options passed to nvim_open_win
      border = 'single',
      style = 'minimal',
      relative = 'cursor',
      row = 0,
      col = 1
    },
  }
}
