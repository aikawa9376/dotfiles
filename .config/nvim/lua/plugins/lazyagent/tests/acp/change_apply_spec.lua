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
    put_blob = function(data)
      return store:put(data)
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

  local text_before = "one\nold-a\nmiddle\nold-b\nlast\n"
  local text_after = "one\nnew-a\nmiddle\nnew-b\nlast\n"
  local text_change = {
    operation = "modified",
    path = "hunks.txt",
    before_blob = assert(store:put(text_before)),
    after_blob = assert(store:put(text_after)),
    binary = false,
  }
  write(root .. "/hunks.txt", text_after)
  local hunks = assert(apply.hunks(text_change))
  assert_equal(#hunks, 2, "text hunk count")
  local first_review, canonical = apply.reject_hunks(text_change, root, { 1 })
  assert(first_review, "first hunk reject")
  assert_equal(read(root .. "/hunks.txt"), "one\nold-a\nmiddle\nnew-b\nlast\n", "first hunk content")
  canonical[1].decision = "rejected"
  text_change.hunks = canonical
  text_change.review_blob = first_review
  local second_review = assert(apply.reject_hunks(text_change, root, { 2 }))
  assert(second_review, "second hunk reject")
  assert_equal(read(root .. "/hunks.txt"), text_before, "multiple hunk reject content")

  for _, fixture in ipairs({
    { name = "insert", before = "a\nb\nc\n", after = "a\nx\nb\nc\n" },
    { name = "delete", before = "a\nb\nc\n", after = "a\nc\n" },
  }) do
    local change = {
      operation = "modified",
      path = fixture.name .. ".txt",
      before_blob = assert(store:put(fixture.before)),
      after_blob = assert(store:put(fixture.after)),
      binary = false,
    }
    write(root .. "/" .. change.path, fixture.after)
    assert(apply.reject_hunks(change, root, { 1 }))
    assert_equal(read(root .. "/" .. change.path), fixture.before, fixture.name .. " hunk reject")
  end

  vim.fn.delete(base, "rf")
end

return M
