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
      },
    },
  },
  rainbow = {
    enable = true,
    extended_mode = true, -- Also highlight non-bracket delimiters like html tags, boolean or table: lang -> boolean
    max_file_lines = 750, -- Do not enable for files with more than n lines, int
    -- colors = {}, -- table of hex strings
    -- termcolors = {} -- table of colour name strings
  },
  Context_commentstring = {
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
  yati = {
    enable = false,
  },
})

-- vim.treesitter.language.register("html", "twig")
