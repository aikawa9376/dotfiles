local M = {}

function M.run()
  local Fingerprint = require("lazyagent.acp.workspace_fingerprint")
  local Test = require("lazyagent.acp.worktree_test")
  local root = vim.fn.tempname() .. "-fingerprint"
  vim.fn.mkdir(root, "p")
  local function git(...)
    local argv = { "git", "-C", root }
    vim.list_extend(argv, { ... })
    local result = vim.system(argv):wait()
    assert(result.code == 0, result.stderr)
  end
  local function capture(path)
    local done, value, err = false, nil, nil
    Fingerprint.capture(path or root, function(fingerprint, error_message)
      done, value, err = true, fingerprint, error_message
    end)
    assert(vim.wait(8000, function() return done end, 10), "fingerprint worker did not finish")
    return value, err
  end
  local ok, err = xpcall(function()
    git("init", "--quiet")
    vim.fn.writefile({ "old" }, root .. "/tracked.txt")
    git("add", "tracked.txt")
    local before = assert(capture())
    assert(capture() == before, "unchanged dirty/unborn workspace fingerprint is stable")
    local stat = vim.uv.fs_stat(root .. "/tracked.txt")
    vim.fn.writefile({ "new" }, root .. "/tracked.txt")
    vim.uv.fs_utime(root .. "/tracked.txt", stat.atime.sec, stat.mtime.sec + stat.mtime.nsec / 1e9)
    local dirty = assert(capture())
    assert(dirty ~= before, "same-size edit with restored mtime is caught by ctime")
    git("add", "tracked.txt")
    assert(capture() ~= dirty, "index changes are included even if worktree bytes do not change")
    vim.fn.writefile({ "untracked" }, root .. "/new file.txt")
    local added = assert(capture())
    vim.fn.delete(root .. "/new file.txt")
    assert(capture() ~= added, "untracked file removal changes the fingerprint")
    local missing, missing_err = capture(root .. "/missing")
    assert(missing == nil and missing_err, "unavailable workspace cannot look verified")

    local store_dir = root .. "-store"
    local store = require("lazyagent.acp.thread_store").new({ dir = store_dir })
    local thread = assert(store:create({ provider_id = "fixture", title = "Test freshness", cwd = root }))
    local backend = { update_thread = function(...) return store:update(...) end }
    assert(Test.run(backend, thread, "true"))
    assert(not Test.run(backend, thread, "true"), "duplicate concurrent test is refused")
    assert(vim.wait(15000, function() return store:get(thread.thread_id).metadata.test_result.status ~= "running" end, 10),
      "test should finish asynchronously")
    local report = store:get(thread.thread_id).metadata.test_result
    assert(report.status == "passed" and Test.status(report, assert(capture())) == "passed", "unchanged test result is current")
    assert(Test.run(backend, thread, "printf changed > tracked.txt"))
    assert(vim.wait(15000, function() return store:get(thread.thread_id).metadata.test_result.status ~= "running" end, 10))
    report = store:get(thread.thread_id).metadata.test_result
    assert(report.status == "passed" and report.stale == true, "workspace changed during a passing test is stale")
    vim.fn.delete(store_dir, "rf")
  end, debug.traceback)
  vim.fn.delete(root, "rf")
  vim.fn.delete(root .. "-store", "rf")
  assert(ok, err)
end

return M
