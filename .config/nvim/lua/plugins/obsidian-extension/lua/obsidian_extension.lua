local M = {}

function M.note_frontmatter(note)
  return require("obsidian_extension.features.frontmatter").build(note)
end

function M.setup()
  require("obsidian_extension.features.commands").setup()
  require("obsidian_extension.features.knowledge").setup()
  require("obsidian_extension.features.sidebar").setup()
  require("obsidian_extension.features.menu").setup()
end

return M
