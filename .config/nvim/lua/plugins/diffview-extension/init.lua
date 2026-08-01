return {
  "diffview-extension",
  dir = os.getenv("XDG_CONFIG_HOME") .. "/nvim/lua/plugins/diffview-extension",
  lazy = true,
  dependencies = { "lazyagent" },
  config = function()
    require("diffview_extension").setup()
  end,
}
