local M = {}

local function assert_equal(expected, actual, label)
  if not vim.deep_equal(expected, actual) then
    error(string.format("%s: expected %s, got %s", label, vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local function assert_truthy(value, label)
  if not value then
    error(label or "expected truthy value", 2)
  end
end

local function read_bytes(path)
  local file = assert(io.open(path, "rb"))
  local data = file:read("*a")
  file:close()
  return data
end

function M.run()
  local FileWriter = require("lazyagent.acp.backend.file_writer")
  local uv = vim.uv or vim.loop
  local base = vim.fn.tempname()
  vim.fn.mkdir(base, "p")

  local crlf = base .. "/crlf.txt"
  local file = assert(io.open(crlf, "wb"))
  file:write("old\r\nvalue\r\n")
  file:close()
  assert_truthy(uv.fs_chmod(crlf, 384), "chmod fixture")
  local result, err = FileWriter.write(crlf, "new\nvalue\n")
  assert_truthy(result, "atomic CRLF write: " .. tostring(err))
  assert_equal("crlf", result.newline, "preserved newline style")
  assert_equal("new\r\nvalue\r\n", read_bytes(crlf), "CRLF bytes")
  assert_equal(384, bit.band(uv.fs_stat(crlf).mode, 511), "preserved permissions")

  local modified = base .. "/modified.txt"
  vim.fn.writefile({ "disk" }, modified)
  local bufnr = vim.fn.bufadd(modified)
  vim.fn.bufload(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "unsaved" })
  local denied, denied_err = FileWriter.write(modified, "agent\n")
  assert_equal(nil, denied, "modified buffer denied")
  assert_truthy(denied_err:match("unsaved buffer"), "modified buffer error")
  assert_equal("disk\n", read_bytes(modified), "modified buffer disk unchanged")
  vim.api.nvim_buf_delete(bufnr, { force = true })

  local conflict = base .. "/conflict.txt"
  vim.fn.writefile({ "before" }, conflict)
  local conflict_result, conflict_err = FileWriter.write(conflict, "agent\n", {
    before_commit = function(path)
      vim.fn.writefile({ "external" }, path)
    end,
  })
  assert_equal(nil, conflict_result, "concurrent write denied")
  assert_truthy(conflict_err:match("file changed"), "concurrent write error")
  assert_equal("external\n", read_bytes(conflict), "concurrent write preserved")

  local invalid = base .. "/invalid.txt"
  local invalid_result, invalid_err = FileWriter.write(invalid, string.char(0xff))
  assert_equal(nil, invalid_result, "invalid UTF-8 denied")
  assert_truthy(invalid_err:match("UTF%-8"), "invalid UTF-8 error")

  assert_equal({}, vim.fn.glob(base .. "/.*.lazyagent-*.tmp", false, true), "temporary files cleaned")
  vim.fn.delete(base, "rf")
end

return M
