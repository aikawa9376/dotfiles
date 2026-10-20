local M = {}

-- TSTree userdata is only a pointer-sized Lua allocation. Its native nodes can
-- be megabytes, so Lua's automatic GC debt misses most reparse allocations.
function M.attach(parser, bufnr)
  if parser._lazyagent_parser_gc or type(parser._parse_regions) ~= "function" then return end
  parser._lazyagent_parser_gc = true
  local parse_regions = parser._parse_regions
  local debt, pending = 0, false
  local threshold = 512 * 1024
  local function current()
    return vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].filetype == "lazyagent_acp"
  end
  local advance
  advance = function()
    if not current() or (jit and not collectgarbage("isrunning")) then
      debt, pending = 0, false
      return
    end
    local started = vim.uv.hrtime()
    repeat
      -- One minimum collector step at a time. A large `step` quota can run
      -- hundreds of expensive native tree finalizers in one UI callback.
      if collectgarbage("step", 0) then
        if debt < threshold then pending = false; return end
        debt = 0
      end
    until vim.uv.hrtime() - started >= 2 * 1e6
    -- Queue behind other work, as native async parsing does. Timers can starve
    -- behind a stream of scheduled parse slices and let native garbage pile up.
    -- Atomic GC/native finalizers can exceed the nominal 2ms slice.
    vim.schedule(advance)
  end
  parser._parse_regions = function(self, ...)
    local changes, count, elapsed = parse_regions(self, ...)
    if type(count) == "number" and count > 0 and current() then
      local bytes = vim.api.nvim_buf_get_offset(bufnr, vim.api.nvim_buf_line_count(bufnr))
      if bytes >= 128 * 1024 then
        debt = math.min(threshold, debt + bytes)
        if debt >= threshold and not pending then
          debt, pending = 0, true
          -- Let the parse stack and references to obsolete trees unwind first.
          vim.schedule(advance)
        end
      end
    end
    return changes, count, elapsed
  end
end

return M
