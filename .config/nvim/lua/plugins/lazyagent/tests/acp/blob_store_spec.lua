local M = {}

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run()
  local BlobStore = require("lazyagent.acp.blob_store")
  local root = vim.fn.tempname() .. "-blob-store"
  local store = BlobStore.new({ dir = root })

  local first = assert(store:put("same content"))
  local duplicate = assert(store:put("same content"))
  assert_equal(first, duplicate, "content deduplication")
  assert_equal(assert(store:get(first)), "same content", "blob round trip")

  local binary_path = root .. "/fixture.bin"
  vim.fn.mkdir(root, "p")
  local uv = vim.uv or vim.loop
  local fd = assert(uv.fs_open(binary_path, "w", 420))
  assert_equal(assert(uv.fs_write(fd, "before\0after", 0)), 12, "binary fixture write")
  uv.fs_close(fd)
  local binary = assert(store:put_file(binary_path))
  assert_equal(binary.binary, true, "binary detection")
  assert(assert(store:get(binary)):find("\0", 1, true), "binary blob round trip")

  local missing, invalid_err = store:get("invalid")
  assert_equal(missing, nil, "invalid reference result")
  assert(tostring(invalid_err):match("invalid sha256"), "invalid reference error")
  vim.fn.delete(root, "rf")
end

return M
