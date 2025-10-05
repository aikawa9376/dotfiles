return {
  "sindrets/diffview.nvim",
  cmd = { 'DiffviewOpen', 'DiffviewFileHistory' },
  keys = {
    { "<Leader>gH", ":DiffviewFileHistory %<CR>", mode= { "n", "x" }, silent = true },
    { "<Leader>gD", ":DiffviewOpen origin/develop -- %" }
  },
  opts = {
    file_panel = {
      win_config = {
        position = vim.o.columns > 120 and "left" or "bottom",
        height = 10
      },
    },
    key_bindings = {
      disable_defaults = false, -- Disable the default keymaps
      view = {
        { "n", "q", "<CMD>tabclose<CR>" },
      },
      file_panel = {
        { "n", "q", "<CMD>tabclose<CR>" },
      },
      file_history_panel = {
        { "n", "q", "<CMD>tabclose<CR>" },
      },
      option_panel = {
        { "n", "q", "<CMD>tabclose<CR>" },
      },
      help_panel = {
        { "n", "q", "<CMD>tabclose<CR>" },
      },
    },
  }
}
