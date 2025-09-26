return {
  "quick-toggle",
  dir = os.getenv("XDG_CONFIG_HOME") .. "/nvim/lua/plugins/quick-toggle",
  keys = {
    { "QQ", function () require"quick-toggle".toggle() end  },
    { "]q", function () require"quick-toggle".next_item() end, mode = "n" },
    { "[q", function () require"quick-toggle".previous_item() end, mode = "n" },
  }
}