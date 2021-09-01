require'nvim-treesitter.configs'.setup {
  ensure_installed = { "rust", "html", "css", "python", "javascript", "typescript", "toml", "yaml", "json", "go", "lua", "vue", "php" },
  highlight = {
    enable = true,
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
}
