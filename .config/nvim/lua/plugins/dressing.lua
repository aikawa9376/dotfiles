require('dressing').setup({
  input = {
    -- relative = "cursor",
    -- border = "single",
    -- override = function(conf)
    --   print(vim.inspect(conf))
    --   return conf
    -- end,
  },
  select = {
    backend = {"builtin"},
    -- builtin = {
      -- anchor = "none",
      -- border = "none",
      -- relative = "cursor",
      -- override = function(conf)
      --   print(vim.inspect(conf))
      --   return conf
      -- end,
    -- }
  }
})
