local M = {}

function M.run()
  local attach = require("lazyagent.acp.parser_gc").attach
  local schedule, hrtime, gc = vim.schedule, vim.uv.hrtime, collectgarbage
  local callbacks, steps = {}, {}
  local finished, running = true, true
  vim.schedule = function(fn) callbacks[#callbacks + 1] = fn end
  _G.collectgarbage = function(kind, budget)
    if kind == "isrunning" then return running end
    assert(kind == "step" and budget == 0,
      "parser GC uses minimum steps without full collections or global option changes")
    steps[#steps + 1] = budget
    return finished
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "lazyagent_acp"
  local count, changes = 1, {}
  local parser = { _parse_regions = function() return changes, count, 42 end }
  local function reparse()
    for _ = 1, 4 do parser:_parse_regions() end
  end
  local ok, err = xpcall(function()
    attach(parser, buf)
    local wrapper = parser._parse_regions
    attach(parser, buf)
    assert(parser._parse_regions == wrapper, "repeated starts do not stack GC wrappers")
    local result, parsed, time = parser:_parse_regions()
    assert(result == changes and parsed == 1 and time == 42, "native parse results stay intact")
    assert(#callbacks == 0, "small transcripts need no additional GC work")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { string.rep("text ", 30000) })
    count = 0
    reparse()
    assert(#callbacks == 0, "cache hits and redraws without parsing schedule no work")
    count = 1
    parser:_parse_regions()
    assert(#callbacks == 0, "a single reparse does not start a collection job")
    reparse()
    assert(#callbacks == 1 and #steps == 0, "native parse debt defers and coalesces GC work")
    table.remove(callbacks, 1)()
    assert(#steps == 1 and #callbacks == 0, "a finished cycle stops the job")
    vim.bo[buf].filetype = "markdown"
    reparse()
    assert(#callbacks == 0, "ordinary Markdown keeps its GC policy")
    vim.bo[buf].filetype = "lazyagent_acp"
    reparse()
    vim.bo[buf].filetype = "markdown"
    table.remove(callbacks, 1)()
    assert(#steps == 1, "a filetype change cancels queued work")
    vim.bo[buf].filetype = "lazyagent_acp"
    local clock = 0
    vim.uv.hrtime = function() clock = clock + 3000000; return clock end
    finished = false
    reparse()
    table.remove(callbacks, 1)()
    assert(#callbacks == 1, "an unfinished cycle yields through the scheduler")
    reparse(); reparse()
    assert(#callbacks == 1, "new parse debt does not create parallel collector jobs")
    finished = true
    table.remove(callbacks, 1)()
    assert(#callbacks == 1, "parsing during collection requests one more cycle")
    table.remove(callbacks, 1)()
    assert(#callbacks == 0, "the extra completed cycle drains the job")
    vim.uv.hrtime = hrtime
    if jit then
      reparse()
      running = false
      local before = #steps
      table.remove(callbacks, 1)()
      assert(#steps == before and #callbacks == 0, "an explicitly stopped collector stays stopped")
      running = true
    end
    reparse()
    vim.api.nvim_buf_delete(buf, { force = true })
    table.remove(callbacks, 1)()
    assert(#callbacks == 0, "wiped buffers discard queued work safely")
  end, debug.traceback)
  vim.schedule, vim.uv.hrtime, _G.collectgarbage = schedule, hrtime, gc
  if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
  assert(ok, err)
end

return M
