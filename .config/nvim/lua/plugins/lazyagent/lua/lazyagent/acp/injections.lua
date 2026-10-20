local M = {}

-- Neovim clips captures to the parent injection *after* checking for empty
-- ranges. Following an edit and a viewport-only parse, clipping an old tree's
-- capture can produce {}. Tree-sitter interprets that as the entire source.
-- Guard the ACP parser instances, including children created on later parses;
-- keep normal Markdown and the native LanguageTree class unchanged.
function M.guard(parser)
  if parser._lazyagent_bounded_injections or type(parser._add_injections) ~= "function" then return end
  parser._lazyagent_bounded_injections = true
  local add = parser._add_injections
  parser._add_injections = function(self, injections)
    local bounded = {}
    for lang, regions in pairs(injections) do
      local kept = {}
      for _, region in ipairs(regions) do
        if #region > 0 then kept[#kept + 1] = region end
      end
      if #kept > 0 then bounded[lang] = kept end
    end
    add(self, bounded)
    for _, child in pairs(self:children()) do M.guard(child) end
  end
  for _, child in pairs(parser:children()) do M.guard(child) end
end

return M
