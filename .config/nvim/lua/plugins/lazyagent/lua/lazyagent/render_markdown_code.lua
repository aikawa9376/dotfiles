local Code = require("render-markdown.render.markdown.code")
local str = require("render-markdown.lib.str")
local Render = setmetatable({}, { __index = Code })
Render.__index = Render

local function each_range(self, first, last, callback)
  -- Use the external renderer's own cached view, so its scroll invalidation
  -- and the marks prepared here agree. Its range endpoints are inclusive.
  for _, range in ipairs(self.context.view.ranges) do
    local start_row, end_row = math.max(first, range[1]), math.min(last, range[2])
    if start_row <= end_row then callback(start_row, end_row) end
  end
end

function Render:background(first, last)
  each_range(self, first, last, function(start_row, end_row)
    Code.background(self, start_row, end_row)
  end)
end

function Render:padding(background)
  local col = self.node.start_col
  local first, last = self.node.start_row, self.node.end_row - 1
  if col == 0 and self.data.margin <= 0 and self.data.padding <= 0 then return end
  local highlight = background and self.config.highlight or nil
  each_range(self, first, last, function(start_row, end_row)
    local lines = col > 0 and vim.api.nvim_buf_get_lines(self.context.buf, start_row, end_row + 1, false) or {}
    for row = start_row, end_row do
      local line = self:line()
      if col > 0 and str.width(lines[row - start_row + 1]) == 0 then line:pad(col) end
      line:pad(self.data.margin)
      if row > first and row < last then line:pad(self.data.padding, highlight) end
      if not line:empty() then
        self.marks:add(self.config, false, row, col, {
          priority = 100,
          virt_text = line:get(),
          virt_text_pos = "inline",
        })
      end
    end
  end)
end

return Render
