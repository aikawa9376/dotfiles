return {
  "rachartier/tiny-inline-diagnostic.nvim",
  event = "BufRead",
  config = true,
  opts = {
    preset = "minimal",
    options = {
      use_icons_from_diagnostic = true,
    }
  }
}
