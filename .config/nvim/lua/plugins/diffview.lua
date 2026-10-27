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
        vim.api.nvim_set_option_value('wrap', false, { win = winid, scope = 'local' })
        vim.w[winid].git_split_side = { buf = bufnr, symbol = ctx.symbol, layout = ctx.layout_name }
        require('git.features.split_diff').setup()
      end,
    },
    key_bindings = {
      disable_defaults = false, -- Disable the default keymaps
      view = {
        { "n", "q", "<CMD>tabclose<CR>" },
        { "n", "gk", function() require('diffview_extension.pr_comments').open() end, { desc = 'Read PR comment' } },
        { "n", "gct", function() require('diffview_extension.pr_comments').list() end, { desc = 'List all PR review threads' } },
        { "n", "]t", function() require('diffview_extension.pr_comments').navigate(1) end, { desc = 'Next PR comment in this file' } },
        { "n", "[t", function() require('diffview_extension.pr_comments').navigate(-1) end, { desc = 'Previous PR comment in this file' } },
        { "n", "gp", function() require('diffview_extension.github_context').open() end, { desc = 'Open related PR' } },
        { "n", "gA", function() require('diffview_extension.github_context').actions() end, { desc = 'Related PR actions' } },
        { "n", "gR", function() require('diffview_extension.github_context').refresh(nil, true) end, { desc = 'Refresh related PRs' } },
        { "n", "]C", function() require("diffview_extension.commit_navigation").older() end, { desc = "Older commit" } },
        { "n", "[C", function() require("diffview_extension.commit_navigation").newer() end, { desc = "Newer commit" } },
      },
      file_panel = {
        { "n", "q", "<CMD>tabclose<CR>" },
        { "n", "<cr>", function() require('diffview_extension.github_context').select_entry() end, { desc = 'Open file or related PR' } },
        { "n", "<2-LeftMouse>", function() require('diffview_extension.github_context').select_entry() end, { desc = 'Open file or related PR' } },
        { "n", "gk", function() require('diffview_extension.pr_comments').open() end, { desc = 'Read PR comment' } },
        { "n", "gct", function() require('diffview_extension.pr_comments').list() end, { desc = 'List all PR review threads' } },
        { "n", "]t", function() require('diffview_extension.pr_comments').navigate(1) end, { desc = 'Next PR comment in this file' } },
        { "n", "[t", function() require('diffview_extension.pr_comments').navigate(-1) end, { desc = 'Previous PR comment in this file' } },
        { "n", "gp", function() require('diffview_extension.github_context').open() end, { desc = 'Open related PR' } },
        { "n", "gA", function() require('diffview_extension.github_context').actions() end, { desc = 'Related PR actions' } },
        { "n", "gR", function() require('diffview_extension.github_context').refresh(nil, true) end, { desc = 'Refresh related PRs' } },
        { "n", "]C", function() require("diffview_extension.commit_navigation").older() end, { desc = "Older commit" } },
        { "n", "[C", function() require("diffview_extension.commit_navigation").newer() end, { desc = "Newer commit" } },
      },
      file_history_panel = {
        { "n", "q", "<CMD>tabclose<CR>" },
        { "n", "<cr>", function() require('diffview_extension.github_context').select_entry() end, { desc = 'Open file or related PR' } },
        { "n", "gk", function() require('diffview_extension.pr_comments').open() end, { desc = 'Read PR comment' } },
        { "n", "gct", function() require('diffview_extension.pr_comments').list() end, { desc = 'List all PR review threads' } },
        { "n", "]t", function() require('diffview_extension.pr_comments').navigate(1) end, { desc = 'Next PR comment in this file' } },
        { "n", "[t", function() require('diffview_extension.pr_comments').navigate(-1) end, { desc = 'Previous PR comment in this file' } },
        { "n", "gp", function() require('diffview_extension.github_context').open() end, { desc = 'Open related PR' } },
        { "n", "gA", function() require('diffview_extension.github_context').actions() end, { desc = 'Related PR actions' } },
        { "n", "gR", function() require('diffview_extension.github_context').refresh(nil, true) end, { desc = 'Refresh related PRs' } },
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
