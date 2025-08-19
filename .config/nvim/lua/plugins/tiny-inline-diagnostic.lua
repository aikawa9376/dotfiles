return {
  "rachartier/tiny-inline-diagnostic.nvim",
  event = "BufReadPre",
  opts = {
    preset = "minimal",
    options = {
      use_icons_from_diagnostic = true,
    }
  }
}
