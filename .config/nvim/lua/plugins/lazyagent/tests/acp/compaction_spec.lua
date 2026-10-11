local M = {}

function M.run()
  local marker = "... earlier transcript omitted from buffer ..."
  local sections = require("lazyagent.acp.view_buffer.sections")
  local view = require("lazyagent.acp.view_buffer.compaction").new({
    transcript_truncated_marker = marker,
  })
  local path = vim.fn.tempname() .. "-bounded-tail.log"
  local long_line = ' + local message = "' .. string.rep("long code ", 20) .. '"'
  local raw = { "─ Tool ─", " Path: old.lua", " ```lua", " old code", " ```",
    " Path: another.lua", " ```lua", " older code", " ```",
    "─ Assistant ─", " ```lua", long_line, " ```" }
  vim.fn.writefile(raw, path)
  -- The limit begins at an orphan close within a multi-file Tool section.
  local expected = { marker, "─ Assistant ─", " ```lua", long_line, " ```" }
  for _, fallback in ipairs({ false, true }) do
    local executable = vim.fn.executable
    if fallback then
      vim.fn.executable = function(name) return name == "tail" and 0 or executable(name) end
    end
    local ok, result = pcall(view.read_transcript_lines, path, 9)
    vim.fn.executable = executable
    assert(ok, result)
    assert(vim.deep_equal(result, expected), "bounded tail starts at a complete section")
    local buf = vim.api.nvim_create_buf(false, true)
    local diff = require("lazyagent.acp.view_diff").new({})
    local normalized = diff.normalize_diff_display_lines(buf, result, 60, 0)
    assert(normalized[4] ~= long_line and normalized[4]:find("...", 1, true),
      "code after an omitted close is still clipped")
    assert(vim.fn.strdisplaywidth(normalized[4]) <= 60, "clipped code fits the window")
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  assert(vim.deep_equal(vim.fn.readfile(path), raw), "display trimming leaves raw history unchanged")
  assert(vim.deep_equal(view.read_transcript_lines(path, #raw), raw), "unbounded history keeps its opening section")
  assert(vim.deep_equal(view.read_transcript_lines(path, 4), expected), "a limit already on a heading is unchanged")

  -- A single oversized live section has no complete boundary within the tail.
  local live = { "─ Assistant ─", " ```lua" }
  for i = 1, 30 do live[#live + 1] = " code " .. i end
  vim.fn.writefile(live, path)
  local tail = view.read_transcript_lines(path, 12)
  assert(#tail == 13 and tail[1] == marker and tail[#tail] == live[#live],
    "the current oversized section retains its bounded output")
  vim.fn.delete(path)
end

return M
