return {
  "DrKJeff16/project.nvim",
  event = "BufReadPre",
  opts = {
      -- Manual mode doesn't automatically change your root directory, so you have
      -- the option to manually do so using `:ProjectRoot` command.
      manual_mode = false,

      lsp = {
        enable = true,
        igonore = { "lua_ls" }
      },

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

      -- Show hidden files in telescope
      show_hidden = false,

      -- When set to false, you will get a message when project.nvim changes your
      -- directory.
      silent_chdir = true,

      -- Path where project.nvim will store the project history for use in
      -- telescope
      datapath = vim.fn.stdpath("data"),
    }
}
