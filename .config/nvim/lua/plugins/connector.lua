return {
  "aikawa9376/connector.nvim",
  cmd = "Connector",
  build = function()
    require("connector").install()
  end,
  config = function()
    require("connector").setup({
    })
  end,
}
