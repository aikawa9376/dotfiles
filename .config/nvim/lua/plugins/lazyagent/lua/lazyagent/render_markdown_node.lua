local markdown_renderer = require("lazyagent.markdown_renderer")
local Node = markdown_renderer.require("lib.node")
local Bounded = setmetatable({}, { __index = Node })
Bounded.__index = function(self, key)
  local value = rawget(Bounded, key)
  if value ~= nil then return value end
  -- Inkstone uses a function here to retrieve node text lazily.
  local index = Node.__index
  if type(index) == "function" then return index(self, key) end
  return index[key]
end
-- Lua resolves comparison metamethods directly on the instance's metatable.
-- Table renderers sort these nodes; __index inheritance alone is insufficient.
Bounded.__lt = Node.__lt

-- Only nodes created by LazyAgent's custom handler use this adapter. Keep the
-- installed renderer and ordinary Markdown nodes unchanged.
function Bounded.wrap(node)
  return setmetatable(node, Bounded)
end

function Bounded:create(node)
  return Bounded.wrap(Node.new(self.buf, node))
end

function Bounded:sibling_count(target, level)
  local count, previous_row, previous_col = 0, math.huge, math.huge
  local node = self:get()
  while node and node:type() == target do
    local row, col, end_row, end_col = node:range()
    -- Edited, off-screen injection trees can retain collapsed nodes. Their
    -- prev_sibling traversal can cycle. Real preceding siblings have content
    -- and strictly decreasing start positions, including on the same line.
    if end_row < row or (end_row == row and end_col <= col)
      or row > previous_row or (row == previous_row and col >= previous_col) then
      break
    end
    if level ~= nil and self:create(node):level(false) ~= level then break end
    previous_row, previous_col = row, col
    count = count + 1
    node = node:prev_sibling()
  end
  return count
end

return Bounded
