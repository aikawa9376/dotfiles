local M = {}

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run()
  local Snapshot = require("lazyagent.acp.workspace_snapshot")
  local function run(argv)
    local command = table.concat(argv, " ")
    if command:match("rev%-parse %-%-show%-toplevel$") then
      return { code = 0, stdout = "/repo\n", stderr = "" }
    end
    if command:match("ls%-files") then
      return { code = 0, stdout = "dirty name.lua\0new.txt\0tracked.lua\0", stderr = "" }
    end
    if command:match("status %-%-porcelain") then
      return { code = 0, stdout = " M dirty name.lua\0?? new.txt\0R  renamed.lua\0old.lua\0", stderr = "" }
    end
    if command:match("rev%-parse HEAD$") then
      return { code = 0, stdout = "deadbeef\n", stderr = "" }
    end
    error("unexpected command: " .. command)
  end
  local snapshot = Snapshot.capture("/repo/subdir", {
    run = run,
    stat = function(path)
      if path == "/repo/new.txt" then
        return { type = "file", size = 3, mtime = { sec = 12, nsec = 34 } }
      end
      return { type = "file", size = 10, mtime = { sec = 1, nsec = 2 } }
    end,
    blob_store = {
      put_file = function(_, path)
        return {
          algorithm = "sha256",
          hash = path:match("new%.txt$") and string.rep("b", 64) or string.rep("a", 64),
          size = path:match("new%.txt$") and 3 or 10,
          binary = false,
        }
      end,
    },
    clock = function()
      return "2026-07-15T01:02:03Z"
    end,
  })

  assert_equal(snapshot.schema_version, 1, "snapshot schema")
  assert_equal(snapshot.root, "/repo", "git workspace root")
  assert_equal(snapshot.vcs, { kind = "git", head = "deadbeef" }, "git identity")
  assert_equal(snapshot.captured_at, "2026-07-15T01:02:03Z", "capture timestamp")
  assert_equal(#snapshot.files, 3, "workspace manifest")
  assert_equal(snapshot.files[2].path, "new.txt", "sorted workspace paths")
  assert_equal(snapshot.files[2].size, 3, "workspace file stat")
  assert_equal(snapshot.files[2].blob.hash, string.rep("b", 64), "workspace blob reference")
  assert_equal(#snapshot.dirty, 3, "dirty state count")
  assert_equal(snapshot.dirty[1].worktree_status, "M", "worktree status")
  assert_equal(snapshot.dirty[3].original_path, "old.lua", "rename source")
  assert_equal(snapshot.untracked, { "new.txt" }, "untracked state")

  local changes = Snapshot.diff({
    files = {
      { path = "deleted.lua", exists = true, type = "file", size = 2, mtime = { sec = 1, nsec = 0 } },
      { path = "modified.lua", exists = true, type = "file", size = 4, mtime = { sec = 1, nsec = 0 } },
    },
  }, {
    files = {
      { path = "added.lua", exists = true, type = "file", size = 3, mtime = { sec = 2, nsec = 0 } },
      { path = "modified.lua", exists = true, type = "file", size = 5, mtime = { sec = 2, nsec = 0 } },
    },
  })
  assert_equal(changes, {
    { path = "added.lua", operation = "added", after_size = 3, binary = false },
    { path = "deleted.lua", operation = "deleted", before_size = 2, binary = false },
    { path = "modified.lua", operation = "modified", before_size = 4, after_size = 5, binary = false },
  }, "workspace manifest diff")

  local moved = Snapshot.diff({
    files = {
      {
        path = "old.lua",
        exists = true,
        size = 4,
        blob = { hash = string.rep("c", 64) },
        binary = true,
      },
    },
    dirty = {},
  }, {
    files = {
      {
        path = "new.lua",
        exists = true,
        size = 5,
        blob = { hash = string.rep("d", 64) },
        binary = true,
      },
    },
    dirty = {
      { path = "new.lua", original_path = "old.lua", index_status = "R", worktree_status = " " },
    },
  })
  assert_equal(moved, {
    {
      path = "new.lua",
      previous_path = "old.lua",
      operation = "moved",
      before_size = 4,
      after_size = 5,
      before_blob = { hash = string.rep("c", 64) },
      after_blob = { hash = string.rep("d", 64) },
      binary = true,
    },
  }, "workspace rename classification")

  local showed_large_blob = false
  local large_changes = Snapshot.diff({
    root = "/repo",
    vcs = { kind = "git", head = "deadbeef" },
    files = {
      { path = "large.bin", exists = true, type = "file", size = 2, mtime = { sec = 1, nsec = 0 } },
    },
  }, {
    files = {
      { path = "large.bin", exists = true, type = "file", size = 10, mtime = { sec = 2, nsec = 0 } },
    },
  }, {
    blob_store = {
      max_blob_bytes = 4,
      put = function() error("oversized content must not reach the blob store") end,
    },
    run = function(argv)
      local command = table.concat(argv, " ")
      if command:match("cat%-file %-s") then
        return { code = 0, stdout = "9\n", stderr = "" }
      end
      showed_large_blob = true
      return { code = 0, stdout = string.rep("x", 9), stderr = "" }
    end,
  })
  assert_equal(showed_large_blob, false, "oversized git blob skipped before git show")
  assert_equal(large_changes[1].before_blob, nil, "oversized baseline has no blob")

  local stored = {}
  local committed_changes = Snapshot.diff({
    root = "/repo",
    vcs = { kind = "git", head = "before-head" },
    files = {
      { path = "committed.lua", exists = true, type = "file", size = 7, mtime = { sec = 1, nsec = 0 } },
    },
  }, {
    root = "/repo",
    vcs = { kind = "git", head = "after-head" },
    files = {
      { path = "committed.lua", exists = true, type = "file", size = 6, mtime = { sec = 2, nsec = 0 } },
    },
  }, {
    blob_store = {
      max_blob_bytes = 1024,
      put = function(_, data)
        stored[#stored + 1] = data
        return { algorithm = "sha256", hash = vim.fn.sha256(data), size = #data }
      end,
    },
    run = function(argv)
      local command = table.concat(argv, " ")
      if command:match("cat%-file %-s") then return { code = 0, stdout = "7\n", stderr = "" } end
      if command:match("before%-head:committed%.lua") then return { code = 0, stdout = "before\n", stderr = "" } end
      if command:match("after%-head:committed%.lua") then return { code = 0, stdout = "after\n", stderr = "" } end
      error("unexpected committed blob command: " .. command)
    end,
  })
  assert_equal(stored, { "before\n", "after\n" }, "clean committed sides are loaded only from their snapshot heads")
  assert(committed_changes[1].before_blob and committed_changes[1].after_blob, "committed change keeps both blobs")

  local realtime_before = { hash = string.rep("e", 64), size = 6 }
  local realtime_after = { hash = string.rep("f", 64), size = 5 }
  local realtime_changes = Snapshot.diff({
    files = {
      { path = "live.lua", exists = true, type = "file", size = 6, mtime = { sec = 1, nsec = 0 } },
    },
  }, {
    files = {
      { path = "live.lua", exists = true, type = "file", size = 5, mtime = { sec = 2, nsec = 0 } },
    },
  }, {
    realtime_blobs = { ["live.lua"] = { before_blob = realtime_before, after_blob = realtime_after } },
  })
  assert_equal(realtime_changes[1].before_blob, realtime_before, "realtime first revision supplies before blob")
  assert_equal(realtime_changes[1].after_blob, realtime_after, "realtime latest revision supplies after blob")

  local same_size_after = { algorithm = "sha256", hash = string.rep("1", 64), size = 6 }
  local same_size_changes = Snapshot.diff({
    root = "/repo",
    vcs = { kind = "git", head = "same-size-before" },
    files = {
      { path = "same.lua", exists = true, type = "file", size = 6, mtime = { sec = 1, nsec = 0 } },
    },
  }, {
    root = "/repo",
    vcs = { kind = "git", head = "same-size-before" },
    files = {
      { path = "same.lua", exists = true, type = "file", size = 6, mtime = { sec = 1, nsec = 0 } },
    },
  }, {
    realtime_blobs = { ["same.lua"] = { after_blob = same_size_after } },
    blob_store = {
      max_blob_bytes = 1024,
      put = function(_, data)
        return { algorithm = "sha256", hash = vim.fn.sha256(data), size = #data }
      end,
    },
    run = function(argv)
      local command = table.concat(argv, " ")
      if command:match("cat%-file %-s") then return { code = 0, stdout = "6\n", stderr = "" } end
      if command:match("same%-size%-before:same%.lua") then return { code = 0, stdout = "before", stderr = "" } end
      error("unexpected same-size command: " .. command)
    end,
  })
  assert_equal(#same_size_changes, 1, "realtime blob detects same-size same-mtime edits")
  assert_equal(same_size_changes[1].operation, "modified", "same-size edit classification")
  assert_equal(same_size_changes[1].after_blob, same_size_after, "same-size edit keeps realtime after blob")
end

return M
