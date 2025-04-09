return {
  "stevearc/dressing.nvim",
  lazy = true,
  opts = {
    input = {
      -- relative = "cursor",
      -- border = "none",
      -- override = function(conf)
      --   print(vim.inspect(conf))
      --   return conf
      -- end,
    },
    select = {
      backend = { "fzf_lua", "fzf", "builtin"  },
      builtin = {
        relative = "cursor",
      },
      fzf_lua = {
        winopts = {
          border = "rounded",
          height = 0.4,
          width = 0.6,
          row = 0.5,
          preview = nil,
          split = false,
        },
      },
    }
  }
}
