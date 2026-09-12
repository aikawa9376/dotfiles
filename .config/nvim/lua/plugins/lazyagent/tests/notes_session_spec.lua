local M = {}

function M.run()
  local notes = require("lazyagent.notes")
  local extension = require("lazyagent.resession_extension")
  local original_agent = package.loaded.lazyagent
  local initial_buf = vim.api.nvim_get_current_buf()
  local root = vim.fn.tempname() .. "-note-session"
  vim.fn.mkdir(root, "p")
  local function git(...)
    local args = { "git", "-C", root }; vim.list_extend(args, { ... })
    local result = vim.system(args, { text = true }):wait()
    assert(result.code == 0, result.stderr)
    return vim.trim(result.stdout)
  end
  git("init", "-q")
  local path = root .. "/sample.lua"
  vim.fn.writefile({ "one", "two", "three", "four" }, path)
  git("add", ".")
  git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "initial")
  local commit = git("rev-parse", "HEAD")
  notes._reset()
  local normal = vim.fn.bufadd(path)
  vim.bo[normal].swapfile = false
  vim.fn.bufload(normal)
  notes.add({ bufnr = normal, root = root, start_line = 2, end_line = 3, text = "normal", icon = "!" })
  vim.api.nvim_buf_set_lines(normal, 0, 0, false, { "inserted" })
  vim.fn.writefile(vim.api.nvim_buf_get_lines(normal, 0, -1, false), path)
  local uri = "diffview://" .. root .. "/.git/" .. commit .. "/sample.lua"
  local review = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(review, uri)
  vim.api.nvim_buf_set_lines(review, 0, -1, false, { "one", "two", "three", "four" })
  notes.add({ bufnr = review, start_line = 2, text = "review" })
  local anonymous = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(anonymous, 0, -1, false, { "unsaved snippet" })
  notes.add({ bufnr = anonymous, root = root, text = "anonymous" })
  local agent_loaded
  package.loaded.lazyagent = {
    resession_snapshot = function() return nil end, -- Notes persist without an agent session.
    resession_post_load = function(data) agent_loaded = data end,
  }
  local snapshot = vim.json.decode(vim.json.encode(extension.on_save()))
  assert(snapshot.notes.version == 1 and #snapshot.notes.entries == 3)
  for _, entry in ipairs(snapshot.notes.entries) do
    assert(entry.bufnr == nil and entry.bindings == nil and entry.mark_id == nil and entry.id == nil,
      "only durable note data is serialized")
  end
  assert(snapshot.notes.entries[1].start_line == 3 and snapshot.notes.entries[1].end_line == 4)
  assert(snapshot.notes.entries[2].source.blob == git("rev-parse", commit .. ":sample.lua"))
  assert(snapshot.notes.entries[3].excerpt[1] == "unsaved snippet")
  extension.on_pre_load(snapshot)
  assert(notes.count({ root = root }) == 0, "pre-load removes old session Notes")
  for _, buf in ipairs({ normal, review, anonymous }) do vim.api.nvim_buf_delete(buf, { force = true }) end
  normal = vim.fn.bufadd(path)
  vim.bo[normal].swapfile = false
  vim.fn.bufload(normal)
  vim.wait(20)
  assert(#vim.api.nvim_buf_get_extmarks(normal, notes.namespace, 0, -1, {}) == 0, "buffer reopen alone does not restore saved Notes")
  extension.on_post_load(snapshot)
  assert(agent_loaded == snapshot, "agent lifecycle still receives the snapshot")
  assert(vim.wait(1000, function() return notes.count({ root = root }) == 3 end, 10))
  assert(#vim.api.nvim_buf_get_extmarks(normal, notes.namespace, 0, -1, {}) == 3, "loaded file gets restored marks")
  assert(notes.show_at_cursor({ bufnr = normal, lnum = 3, focus = false, silent = true }))
  review = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(review, uri)
  vim.api.nvim_buf_set_lines(review, 0, -1, false, { "one", "two", "three", "four" })
  vim.api.nvim_exec_autocmds("BufWinEnter", { buffer = review })
  assert(vim.wait(1000, function() return #vim.api.nvim_buf_get_extmarks(review, notes.namespace, 0, -1, {}) == 3 end, 10),
    "revision opened later reconnects restored Note")
  extension.on_post_load(snapshot)
  vim.wait(20)
  assert(notes.count({ root = root }) == 3, "loading the same snapshot replaces rather than duplicates")
  extension.on_pre_load({})
  extension.on_post_load({ session_name = "older-session" })
  vim.wait(20)
  assert(notes.count({ root = root }) == 0, "older sessions without Notes clear the previous session")
  assert(#extension.on_save().notes.entries == 0, "empty state is saved after deletion/session switch")
  notes._reset()
  package.loaded.lazyagent = original_agent
  vim.api.nvim_buf_delete(normal, { force = true })
  vim.api.nvim_buf_delete(review, { force = true })
  if vim.api.nvim_buf_is_valid(initial_buf) then vim.api.nvim_win_set_buf(0, initial_buf) end
  vim.fn.delete(root, "rf")
end

return M
