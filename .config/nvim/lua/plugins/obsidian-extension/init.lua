return {
  "obsidian-extension",
  dir = os.getenv("XDG_CONFIG_HOME") .. "/nvim/lua/plugins/obsidian-extension",
  lazy = true,
  config = function()
    require("obsidian_extension").setup()
  end,
}
