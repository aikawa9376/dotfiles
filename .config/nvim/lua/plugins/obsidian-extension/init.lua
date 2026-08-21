return {
  "obsidian-extension",
  dir = os.getenv("XDG_CONFIG_HOME") .. "/nvim/lua/plugins/obsidian-extension",
  lazy = true,
  dependencies = "DrKJeff16/project.nvim",
  opts = {
    dashboard = {
      show_aliases = true,
      sections = {
        { title = "Recent notes", dir = "notes", limit = 10 },
        { title = "Daily notes", dir = "daily", limit = 7 },
        { title = "Ideas", dir = "ideas", limit = 5 },
      },
    },
  },
  config = function(_, opts)
    require("obsidian_extension").setup(opts)
  end,
}
