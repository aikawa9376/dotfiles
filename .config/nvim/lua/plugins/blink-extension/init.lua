return {
  "blink-extension",
  dir = os.getenv("XDG_CONFIG_HOME") .. "/nvim/lua/plugins/blink-extension",
  lazy = true,
  config = function()
    require("blink_extension").setup()
  end,
}
