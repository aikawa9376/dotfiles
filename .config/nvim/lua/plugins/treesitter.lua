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
    enable = false,
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
    enable = true,
    default_lazy = true,
    default_fallback = function(lnum, computed, bufnr)
      if vim.tbl_contains(tm_fts, vim.bo[bufnr].filetype) then
        return require('tmindent').get_indent(lnum, bufnr) + computed
      end
      -- or any other fallback methods
      return require('nvim-yati.fallback').vim_auto(lnum, computed, bufnr)
    end,
  },
})

-- vim.treesitter.language.register("html", "twig")
