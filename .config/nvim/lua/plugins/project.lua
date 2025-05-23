return {
  "ahmedkhalf/project.nvim",
  event = "BufReadPre",
  config = function ()
    require("project_nvim").setup {
      -- Manual mode doesn't automatically change your root directory, so you have
      -- the option to manually do so using `:ProjectRoot` command.
      manual_mode = false,

      -- Methods of detecting the root directory. **"lsp"** uses the native neovim
      -- lsp, while **"pattern"** uses vim-rooter like glob pattern matching. Here
      -- order matters: if one is not detected, the other is used as fallback. You
      -- can also delete or rearangne the detection methods.
      detection_methods = { "lsp", "pattern" },

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

    vim.api.nvim_create_user_command('FindRootDirectory', function()
      print(require("project_nvim.project").get_project_root())
    end, {})
  end
}
