return {
  "flash-scope",
  dir = os.getenv("XDG_CONFIG_HOME") .. "/nvim/lua/plugins/flash-scope",
  keys = {
    { "f", "F", "t", "T", mode = { "n", "x" } },
  },
  config = function()
    require("flash-scope").setup()
  end,
}
