return {
  "laravel-extension",
  dir = os.getenv("XDG_CONFIG_HOME") .. "/nvim/lua/plugins/laravel-extension",
  ft = { "php", "blade" },
  config = function()
    require("laravel_extension").setup()
  end,
}
