return {
  "ravitemer/mcphub.nvim",
  build = "bundled_build.lua",
  cmd = { "MCPHub" },
  opts = {
    use_bundled_binary = true,
    extensions = {
      avante = {
        enabled = true,
        make_slash_commands = true
      }
    }
  }
}
