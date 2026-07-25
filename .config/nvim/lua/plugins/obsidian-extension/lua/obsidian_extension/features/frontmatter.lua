local M = {}

function M.build(note)
  if note.title then
    note:add_alias(note.title)
  end

  local frontmatter = {
    id = note.id,
    aliases = note.aliases,
    tags = note.tags,
  }
  for key, value in pairs(note.metadata or {}) do
    frontmatter[key] = value
  end

  local today = os.date("%Y-%m-%d")
  local path = tostring(note.path or ""):gsub("\\", "/")
  local is_daily = path:match("^daily/") ~= nil or path:find("/daily/", 1, true) ~= nil
  frontmatter.type = frontmatter.type or (is_daily and "daily" or "knowledge")
  frontmatter.source = frontmatter.source or "manual"
  frontmatter.created = frontmatter.created or today
  frontmatter.updated = today
  if not is_daily then
    frontmatter.status = frontmatter.status or "seed"
  end

  return frontmatter
end

return M
