return {
  "lazyconflict",
  dir = os.getenv("XDG_CONFIG_HOME") .. "/nvim/lua/plugins/lazyconflict",
  event = "BufRead",
  cmd = {
    "LazyConflictCheck",
    "LazyConflictQuickfix",
    "LazyConflictDisable",
    "LazyConflictEnable",
  },
  opts = {
  },
  config = function(_, opts)
    require("lazyconflict").setup(opts)
  end
}
