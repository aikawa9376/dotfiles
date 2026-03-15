return {
  "migemo",
  dir = os.getenv("XDG_CONFIG_HOME") .. "/nvim/lua/plugins/migemo",
  dependencies = {
    "folke/flash.nvim",
  },
  config = function()
    require("migemo").setup()
  end,
}
