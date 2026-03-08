return {
  "flash-migemo",
  dir = os.getenv("XDG_CONFIG_HOME") .. "/nvim/lua/plugins/flash-migemo",
  dependencies = {
    "folke/flash.nvim",
  },
  config = function()
    require("flash-migemo").setup()
  end,
}
