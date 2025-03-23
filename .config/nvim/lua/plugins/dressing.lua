return {
  "stevearc/dressing.nvim",
  event = "VeryLazy",
  config = function ()
    require('dressing').setup({
      input = {
        -- relative = "cursor",
        -- border = "none",
        -- override = function(conf)
          --   print(vim.inspect(conf))
          --   return conf
          -- end,
        },
        select = {
          backend = { "builtin" },
          builtin = {
            relative = "cursor",
          }
        }
      })
  end
}
