local M = {}

local uv = vim.uv or vim.loop

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

local function write(path, data)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local fd = assert(uv.fs_open(path, "w", 420))
  assert(uv.fs_write(fd, data, 0))
  uv.fs_close(fd)
end

local function read(path)
  local fd = uv.fs_open(path, "r", 384)
  if not fd then
    return nil
  end
  local stat = assert(uv.fs_fstat(fd))
  local data = assert(uv.fs_read(fd, stat.size, 0))
  uv.fs_close(fd)
  return data
end

function M.run()
  local base = vim.fn.tempname() .. "-change-apply"
  local root = base .. "/workspace"
  local store = require("lazyagent.acp.blob_store").new({ dir = base .. "/blobs" })
  local apply = require("lazyagent.acp.change_apply").new({
    read_blob = function(ref)
      return store:get(ref)
    end,
  })
  local before = assert(store:put("before\0bytes"))
  local after = assert(store:put("after\0bytes"))

  write(root .. "/modified.bin", "after\0bytes")
  assert(apply.reject({
    operation = "modified",
    path = "modified.bin",
    before_blob = before,
    after_blob = after,
  }, root))
  assert_equal(read(root .. "/modified.bin"), "before\0bytes", "modified file reject")

  write(root .. "/conflict.bin", "user edit")
  local rejected, conflict_err = apply.reject({
    operation = "modified",
    path = "conflict.bin",
    before_blob = before,
    after_blob = after,
  }, root)
  assert_equal(rejected, nil, "concurrent edit reject result")
  assert(tostring(conflict_err):match("changed after"), "concurrent edit conflict")
  assert_equal(read(root .. "/conflict.bin"), "user edit", "concurrent edit preserved")

  write(root .. "/added.bin", "after\0bytes")
  assert(apply.reject({ operation = "added", path = "added.bin", after_blob = after }, root))
  assert_equal(read(root .. "/added.bin"), nil, "added file reject")

  assert(apply.reject({ operation = "deleted", path = "deleted.bin", before_blob = before }, root))
  assert_equal(read(root .. "/deleted.bin"), "before\0bytes", "deleted file reject")

  write(root .. "/new.bin", "after\0bytes")
  assert(apply.reject({
    operation = "moved",
    path = "new.bin",
    previous_path = "old.bin",
    before_blob = before,
    after_blob = after,
  }, root))
  assert_equal(read(root .. "/new.bin"), nil, "moved destination reject")
  assert_equal(read(root .. "/old.bin"), "before\0bytes", "moved source restore")

  write(root .. "/first.bin", "after\0bytes")
  write(root .. "/second.bin", "user edit")
  local all_ok = apply.reject_all({
    { operation = "modified", path = "first.bin", before_blob = before, after_blob = after },
    { operation = "modified", path = "second.bin", before_blob = before, after_blob = after },
  }, root)
  assert_equal(all_ok, nil, "reject all preflight result")
  assert_equal(read(root .. "/first.bin"), "after\0bytes", "reject all preflight is non-mutating")

  vim.fn.delete(base, "rf")
end

return M
