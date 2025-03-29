return {
  {
    "nvim-treesitter/nvim-treesitter",
    event = "VeryLazy",
    dependencies = {
      "nvim-treesitter/nvim-treesitter-textobjects" ,
      "windwp/nvim-ts-autotag"
    },
    build = ":TSUpdate",
    config = function ()
      require("nvim-treesitter.configs").setup({
        ensure_installed = "all",
        highlight = {
          enable = true,
          additional_vim_regex_highlight = false,
        },
        incremental_selection = {
          enable = true,
          keymaps = {
            init_selection = "gp",
            node_incremental = "g+",
            scope_incremental = "gp",
            node_decremental = "gm",
          },
        },
        indent = {
          enable = true,
        },
        textobjects = {
          select = {
            enable = true,
            -- Automatically jump forward to textobj, similar to targets.vim
            lookahead = true,
            keymaps = {
              -- You can use the capture groups defined in textobjects.scm
              ["af"] = "@function.outer",
              ["if"] = "@function.inner",
              ["aC"] = "@class.outer",
              ["iC"] = "@class.inner",
              ["aa"] = "@parameter.outer",
              ["ia"] = "@parameter.inner",
            },
          },
        },
        context_commentstring = {
          enable = true,
          enable_autocmd = false,
          config = {
            toml = "# %s",
          },
        },
        matchup = {
          enable = true,
        },
        autotag = {
          enable = true,
        },
      })
    end
  },
  { "m-demare/hlargs.nvim", event = "VeryLazy", opts = { hl_priority = 150 } },
  {
    "HiPhish/rainbow-delimiters.nvim",
    event = "VeryLazy",
    config = function()
      require('rainbow-delimiters.setup').setup{
        highlight = {
          'RainbowDelimiterBlue',
          'RainbowDelimiterGreen',
          'RainbowDelimiterViolet',
          'RainbowDelimiterYellow',
          'RainbowDelimiterOrange',
          'RainbowDelimiterCyan',
          'RainbowDelimiterRed',
        },
      }
    end
  },
  {
    "JoosepAlviste/nvim-ts-context-commentstring",
    lazy = true,
    opts = {
      enable_autocmd = false,
    },
    init = function ()
      vim.g.skip_ts_context_commentstring_module = true
    end
  },
  { "nvim-treesitter/nvim-treesitter-refactor", lazy = true },
  { "nvim-treesitter/playground", lazy = true },
}
