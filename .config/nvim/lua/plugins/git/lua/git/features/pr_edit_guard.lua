-- The metadata and review snapshot share a buffer, but only the draft is mutable.
local M = {}
function M.attach(s, restore)
  local accepted, generation, reverting, rejected
  local function sync()
    accepted = vim.api.nvim_buf_get_lines(s.buf, #s.prefix,
      vim.api.nvim_buf_line_count(s.buf) - #s.suffix, false)
    generation = (generation or 0) + 1
    rejected = false
  end
  vim.api.nvim_buf_attach(s.buf, false, { on_lines = function(_, _, _, first, last, new_last)
    if not s.model or s.rendering or reverting or rejected then return end
    local tail = #s.prefix + #accepted
    -- Coordinates refer to the old buffer. Checking this interval avoids
    -- copying/scanning a potentially large expanded diff on every keystroke.
    if first >= #s.prefix and last <= tail and tail + new_last - last > #s.prefix then sync(); return end
    local previous, version = accepted, generation
    rejected = true
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(s.buf) or generation ~= version then return end
      reverting = true
      -- Rebuild extmarks lost by deleting protected rows, preserving the last
      -- accepted draft and its modified state rather than undoing user edits.
      restore(previous)
      reverting = false
      sync()
    end)
  end })
  return { sync = sync }
end
return M
