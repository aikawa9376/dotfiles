return {
  "obsidian-extension",
  dir = os.getenv("XDG_CONFIG_HOME") .. "/nvim/lua/plugins/obsidian-extension",
  lazy = true,
  dependencies = "DrKJeff16/project.nvim",
  opts = {
    project_root = {
      enabled = false,
    },
    dashboard = {
      show_aliases = true,
      winbar = false,
      preview_width = 0.45,
      folder_depth = 3,
      sections = {
        { title = "Recent notes", dir = "notes", limit = 10, exclude = { "projects", "agent-memory" } },
        { title = "Branch notes", dir = "notes/projects", limit = 8, exclude = { "index.md" } },
        { title = "Daily notes", dir = "daily", limit = 7 },
        { title = "Ideas", dir = "ideas", limit = 5 },
      },
    },
  },
  config = function(_, opts)
    require("obsidian_extension").setup(opts)
  end,
}
