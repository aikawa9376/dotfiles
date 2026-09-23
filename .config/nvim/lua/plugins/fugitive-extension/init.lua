return {
  "fugitive-extension",
  dir = os.getenv("XDG_CONFIG_HOME") .. "/nvim/lua/plugins/fugitive-extension",
  lazy = true,
  cmd = { "GitBlame" },
  keys = {
    { "<Leader>gb", function() require('features.blame').open() end, silent = true, desc = "Git blame" },
  },
  config = true
}
