return {
  "DrKJeff16/project.nvim",
  event = "BufReadPre",
  config = function ()
    vim.g.project_lsp_nowarn = 1

    require("project").setup {
      -- Manual mode doesn't automatically change your root directory, so you have
      -- the option to manually do so using `:ProjectRoot` command.
      manual_mode = false,

      use_lsp = true,

      -- All the patterns used to detect root dir, when **"pattern"** is in
      -- detection_methods
      patterns = {
        ".git",
        "_darcs",
        ".hg",
        ".bzr",
        ".svn",
        "Makefile",
        "package.json",
        "Session.vim",
        "composer.json",
        "docker-compose.yml",
        ".vimrc-local",
      },

      -- Table of lsp clients to ignore by name
      -- eg: { "efm", ... }
      ignore_lsp = { "lua_ls" },

      -- Show hidden files in telescope
      show_hidden = false,

      -- When set to false, you will get a message when project.nvim changes your
      -- directory.
      silent_chdir = true,

      -- Path where project.nvim will store the project history for use in
      -- telescope
      datapath = vim.fn.stdpath("data"),
    }
  end
}
