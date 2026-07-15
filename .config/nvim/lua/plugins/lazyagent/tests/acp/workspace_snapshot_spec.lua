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
end

return M
