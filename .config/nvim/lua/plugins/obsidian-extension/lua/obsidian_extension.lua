local M = {}

function M.note_frontmatter(note)
  return require("obsidian_extension.features.frontmatter").build(note)
end

function M.setup(opts)
  opts = opts or {}
  require("obsidian_extension.features.fzf_picker").setup()
  require("obsidian_extension.features.properties").setup()
  require("obsidian_extension.features.commands").setup()
  require("obsidian_extension.features.related").setup()
  require("obsidian_extension.features.knowledge").setup()
  require("obsidian_extension.features.sidebar").setup()
  require("obsidian_extension.features.project_root").setup()
  require("obsidian_extension.features.dashboard").setup(opts.dashboard)
  require("obsidian_extension.features.menu").setup()
end

return M
