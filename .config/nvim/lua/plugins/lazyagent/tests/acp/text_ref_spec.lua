local M = {}

function M.run()
  local Ref = require("lazyagent.acp.text_ref")
  local uv = vim.uv or vim.loop
  local path = vim.fn.tempname()
  local lines = {}
  for i = 1, 1000 do lines[i] = tostring(i) .. " 日本語 " .. string.rep("x", 90) end
  vim.fn.writefile(lines, path)
  local function read(first, last, opts)
    local chunks = {}
    assert(Ref.each_chunk({ path = path, start_line = first, end_line = last }, function(chunk)
      chunks[#chunks + 1] = chunk
    end, opts))
    return table.concat(chunks)
  end
  local original_read, bytes = uv.fs_read, 0
  uv.fs_read = function(...)
    local data, err = original_read(...)
    bytes = bytes + (type(data) == "string" and #data or 0)
    return data, err
  end
  local ok, err = xpcall(function()
    for i = 1, #lines do assert(read(i, i) == lines[i] .. "\n", "adjacent reference " .. i) end
    assert(bytes <= uv.fs_stat(path).size * 2, "adjacent refs must reuse bounded read blocks")
    for i = #lines, 1, -37 do assert(read(i, i) == lines[i] .. "\n", "backward reference " .. i) end
  end, debug.traceback)
  uv.fs_read = original_read
  assert(ok, err)

  -- An atomic replacement with the same size must invalidate cached content.
  local replacement = path .. ".new"
  local modified = vim.deepcopy(lines)
  modified[1] = modified[1]:gsub("x", "y")
  vim.fn.writefile(modified, replacement)
  assert(uv.fs_rename(replacement, path))
  assert(read(1, 1) == modified[1] .. "\n", "replacement invalidates cache")
  vim.fn.writefile({ "appended" }, path, "a")
  assert(read(1001, 1001) == "appended\n", "append invalidates cache")
  local long = string.rep("長い", 25000)
  vim.fn.writefile({ "", long, "last" }, path, "b")
  assert(read(2, 3, { chunk_bytes = 1024 }) == long .. "\nlast", "long lines and unterminated EOF")
  assert(read(1, 1) == "\n", "empty line")
  assert(read(10, 10) == "", "past EOF")
  assert(Ref.each_chunk({ path = path }, function() return false end), "early stop closes reader")
  local result, callback_err = Ref.each_chunk({ path = path }, function() return false, "stop-error" end)
  assert(not result and callback_err:find("stop-error", 1, true), "callback errors propagate")
  vim.fn.delete(path)
  assert(not Ref.each_chunk({ path = path }, function() end), "removed file is not served from cache")
end

return M
