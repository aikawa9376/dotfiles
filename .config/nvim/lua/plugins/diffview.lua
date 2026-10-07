return {
  "dlyongemallo/diffview.nvim",
  dependencies = {
    'git',
    {
      "diffview-extension",
      dir = os.getenv("XDG_CONFIG_HOME") .. "/nvim/lua/plugins/diffview-extension",
    },
  },
  cmd = { 'DiffviewOpen', 'DiffviewFileHistory' },
  keys = {
    { "<Leader>gH", ":DiffviewFileHistory %<CR>", mode = { "n", "x" }, silent = true },
    { "<Leader>gD", ":DiffviewOpen origin/develop -- %" },
  },
  opts = {
    file_panel = {
      win_config = {
        position = vim.o.columns > 120 and "left" or "bottom",
        height = 10,
      },
    },
    hooks = {
      diff_buf_win_enter = function(bufnr, winid, ctx)
        vim.wo[winid].wrap = false
        vim.w[winid].git_split_side = { buf = bufnr, symbol = ctx.symbol, layout = ctx.layout_name }
        require('git.features.split_diff').setup()
      end,
    },
    key_bindings = {
      disable_defaults = false, -- Disable the default keymaps
      view = {
        { "n", "q", "<CMD>tabclose<CR>" },
        { "n", "]C", function() require("diffview_extension.commit_navigation").older() end, { desc = "Older commit" } },
        { "n", "[C", function() require("diffview_extension.commit_navigation").newer() end, { desc = "Newer commit" } },
      },
      file_panel = {
        { "n", "q", "<CMD>tabclose<CR>" },
        { "n", "]C", function() require("diffview_extension.commit_navigation").older() end, { desc = "Older commit" } },
        { "n", "[C", function() require("diffview_extension.commit_navigation").newer() end, { desc = "Newer commit" } },
      },
      file_history_panel = {
        { "n", "q", "<CMD>tabclose<CR>" },
        { "n", "]C", function() require("diffview_extension.commit_navigation").older() end, { desc = "Older commit" } },
        { "n", "[C", function() require("diffview_extension.commit_navigation").newer() end, { desc = "Newer commit" } },
      },
      option_panel = {
        { "n", "q", "<CMD>tabclose<CR>" },
      },
      help_panel = {
        { "n", "q", "<CMD>tabclose<CR>" },
      },
    },
  },
}
