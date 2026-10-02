local M = {}

local function assert_equal(actual, expected, message)
  assert(actual == expected, string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
end

function M.run()
  package.loaded["lazyagent.watch"] = nil
  local watch = require("lazyagent.watch")
  local test_dir = vim.fn.tempname()
  vim.fn.mkdir(test_dir, "p")

  local dir_handle = assert(watch.start(test_dir))
  assert_equal(dir_handle.dir, test_dir, "directory watch path has no trailing slash")
  assert_equal(watch.is_watching(test_dir .. "/"), true, "directory watch lookup")
  watch.stop(test_dir .. "/")
  assert_equal(watch.is_watching(test_dir), false, "directory watch stop")

  local file = test_dir .. "/note.md"
  vim.fn.writefile({ "test" }, file)
  local callback_handle = assert(watch.add(file, function() end))
  assert_equal(callback_handle.abs, file, "file watch path is normalized")
  assert_equal(callback_handle.key, test_dir, "file watch key is normalized")
  assert_equal(watch.is_watching(file), true, "file watch lookup")
  assert_equal(watch.remove(callback_handle), true, "file watch removal")
  assert_equal(watch.is_watching(file), false, "file watch removed")

  local events = {}
  local directory_handle = assert(watch.add(test_dir .. "/.watch-all", function(path)
    events[path] = true
  end, { debounce_ms = 20 }))
  vim.fn.writefile({ "changed" }, file)
  local missing_agents = test_dir .. "/.agents"
  vim.fn.writefile({}, missing_agents)
  vim.fn.delete(missing_agents)
  vim.wait(500, function()
    return events[file] == true
  end, 10)
  assert_equal(events[file], true, "coalesced real file event retained")
  assert_equal(events[missing_agents], nil, "missing agent metadata event ignored")
  watch.remove(directory_handle)

  local buffer = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buffer, file)
  vim.api.nvim_buf_call(buffer, function() vim.cmd('edit') end)
  watch.enable()
  watch.disable()
  vim.wait(250, function() return false end, 5)
  assert_equal(#watch.list(), 0, "queued update cannot recreate watchers after disable")
  vim.api.nvim_buf_delete(buffer, { force = true })

  -- Stopping an in-flight poll kills the job and ignores its late result.
  local system, executable = vim.system, vim.fn.executable
  local poll_done, killed
  vim.fn.executable = function() return 0 end
  vim.system = function(_, _, done)
    poll_done = done
    return { kill = function() killed = true end }
  end
  local before_windows = #vim.api.nvim_list_wins()
  assert(watch.start_follow({ dir = test_dir, interval_ms = 10 }))
  assert(vim.wait(200, function() return poll_done ~= nil end, 5))
  watch.stop_follow()
  assert(killed, "stop_follow left the find subprocess running")
  poll_done({ code = 0, stdout = file })
  vim.wait(20, function() return false end, 5)
  assert_equal(#vim.api.nvim_list_wins(), before_windows, "late poll reopened a stopped follow window")
  vim.system, vim.fn.executable = system, executable

  watch.stop_all()
  vim.fn.delete(test_dir, "rf")
end

return M
