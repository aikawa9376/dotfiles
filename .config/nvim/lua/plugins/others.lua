return {
  {
    "cappyzawa/trim.nvim",
    event = "BufRead",
    opts = { fb_blocklist = {"markdown"} },
  },
  {
    "xiyaowong/accelerated-jk.nvim",
    opts = { acceleration_table = {35,97,141,212,314,414,514,614} },
    event = "BufRead",
  },
  {
    "ii14/exrc.vim",
    init = function ()  vim.g["exrc#names"] = { ".vimrc.local", ".exrc.lua" }end,
  },
  {
    "tpope/vim-abolish",
    event = "BufRead",
    init = function () vim.g.abolish_no_mappings = 1 end,
  },
  {
    "markonm/traces.vim",
    event = "BufReadPre",
    init = function () vim.g.traces_abolish_integration = 1 end,
  },
  {
    "junegunn/vim-easy-align",
    keys = {
      { "ga", "<Plug>(EasyAlign)", mode = { "n", "x"  }, silent = true }
    }
  },
  {
    "rhysd/git-messenger.vim",
    keys = {
      { "g<space><space>", "<Plug>(git-messenger)", silent = true },
    }
  },
  {
    "akinsho/git-conflict.nvim",
    opts = {
      disable_diagnostics = true,
      highlights = {
        incoming = 'ConflictIncoming',
        current = 'ConflictCurrent',
      }
    }
  },
  {
    "kdheepak/lazygit.nvim",
    keys = {
      { "<Leader>gl", "<cmd>LazyGit<CR>", silent = true }
    },
    config = function ()
      vim.g.lazygit_use_custom_config_file_path = 1
      vim.g.lazygit_config_file_path = os.getenv("XDG_CONFIG_HOME") .. "/lazygit/config_nvim.yml"
      vim.g.lazygit_floating_window_border_chars = {'', '', '', '', '', '', '', ''}
    end
  },
  {
    "folke/lazydev.nvim",
    ft = "lua",
    opts = {
      library = {
        "lazy.nvim",
      }
    }
  },
  {
    "adibhanna/laravel.nvim",
    ft = { "php", "blade" },
    opts = {
      notifications = false,
      keymaps = false,
    },
  },
  {
    "mikesmithgh/kitty-scrollback.nvim",
    cmd = {
      'KittyScrollbackGenerateKittens',
      'KittyScrollbackCheckHealth',
      'KittyScrollbackGenerateCommandLineEditing',
    },
    event = { 'User KittyScrollbackLaunch' },
    opts = {}
  },
  {
    "uga-rosa/translate.nvim",
    cmd = { "Translate" },
    keys = {
      { "gT", "<cmd>Translate ja<CR>", mode = "x", silent = true }
    },
  },
  {
    "aikawa9376/auto-cursorline.nvim",
    event = "BufRead",
    opts = {
      disabled_filetypes_no_cursorline = { "AvantePromptInput", "TelescopePrompt", "terminal", "qf" },
    }
  },
  {
    "adibhanna/phprefactoring.nvim",
    cmd = {
      "PHPExtractVariable", "PHPExtractMethod", "PHPExtractClass", "PHPExtractInterface",
      "PHPIntroduceConstant", "PHPIntroduceField", "PHPIntroduceParameter", "PHPChangeSignature",
      "PHPPullMembersUp", "PHPRenameVariable", "PHPRenameMethod", "PHPRenameClass",
    },
    config = true
  }
}
