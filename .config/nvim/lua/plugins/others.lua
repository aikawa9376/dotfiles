return {
  {
    "lukas-reineke/lsp-format.nvim",
    lazy= true,
    opts = { blade = { exclude = { "intelephense" } } },
  },
  {
    "cappyzawa/trim.nvim",
    event = "VeryLazy",
    opts = { fb_blocklist = {"markdown"} },
  },
  {
    "xiyaowong/accelerated-jk.nvim",
    event = "VeryLazy",
    opts = { acceleration_table = {35,97,141,212,314,414,514,614} },
  },
  {
    "ii14/exrc.vim",
    init = function ()  vim.g["exrc#names"] = { ".vimrc.local", ".exrc.lua" }end,
  },
  {
    "tpope/vim-abolish",
    event = "VeryLazy",
    init = function () vim.g.abolish_no_mappings = 1 end,
  },
  {
    "markonm/traces.vim",
    event = "VeryLazy",
    init = function () vim.g.traces_abolish_integration = 1 end,
  },
  {
    "junegunn/vim-easy-align",
    keys = {
      { "ga", "<Plug>(EasyAlign)", mode = { "n", "x"  }, silent = true }
    }
  },
  {
    "LeafCage/qutefinger.vim",
    keys = {
      { "Q", "<Plug>(qutefinger-toggle-win)", silent = true },
      { "QQ", "<Plug>(qutefinger-toggle-win)", silent = true }
    }
  },
  {
    "rhysd/git-messenger.vim",
    keys = {
      { "g<space>", "<Plug>(git-messenger)", silent = true },
    }
  },
  {
    "kdheepak/lazygit.nvim",
    keys = {
      { "<Leader>gl", "<cmd>LazyGit<CR>", silent = true }
    }
  },
  {
    "aaronhallaert/advanced-git-search.nvim",
    cmd = { "AdvancedGitSearch" },
    config = function ()
      require("advanced_git_search.fzf").setup({})
    end
  },
}
