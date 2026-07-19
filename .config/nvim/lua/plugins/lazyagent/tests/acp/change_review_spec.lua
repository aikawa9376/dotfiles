local M = {}

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run()
  local ChangeReview = require("lazyagent.acp.change_review")
  local thread = {
    thread_id = "thread-1",
    title = "Review fixture",
    change_journal = {
      turns = {
        {
          turn_id = "thread-1:1",
          changes = {
            { operation = "added", path = "lua/older.lua" },
          },
        },
        {
          turn_id = "thread-1:2",
          changes = {
            {
              operation = "modified", path = "lua/a.lua", decision = "kept",
              before_blob = "before-a", after_blob = "after-a",
            },
            { operation = "moved", previous_path = "old.bin", path = "new.bin", binary = true, decision = "rejected" },
          },
        },
      },
    },
  }
  local turn = assert(ChangeReview.latest_turn(thread))
  assert_equal(turn.turn_id, "thread-1:2", "latest changed turn")
  assert_equal(#ChangeReview.changed_turns(thread), 2, "all changed turns remain reviewable")
  assert_equal(ChangeReview.drawer_lines(thread, turn), {
    "LazyAgent ACP Changes — Review fixture",
    "Turn thread-1:2 · 2 file(s)",
    "`=` inline diff  `<CR>` side-by-side  `o` open all",
    "M  lua/a.lua [approved]",
    "R  old.bin -> new.bin [binary] [rejected]",
  }, "changed files drawer")

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, ChangeReview.drawer_lines(thread, turn))
  assert_equal(ChangeReview.apply_drawer_highlights(bufnr, turn), true, "drawer highlights applied")
  local highlighted = vim.api.nvim_buf_get_extmarks(
    bufnr,
    vim.api.nvim_get_namespaces().LazyAgentACPChanges,
    0,
    -1,
    { details = true }
  )
  assert(#highlighted >= 8, "drawer should include title, status, path, and decision highlights")
  vim.api.nvim_buf_delete(bufnr, { force = true })

  local review = ChangeReview.new({
    read_blob = function(ref)
      return ({
        ["before-a"] = "local value = 1\nreturn value\n",
        ["after-a"] = "local value = 2\nreturn value\n",
      })[ref] or ""
    end,
  })
  local drawer = assert(review.open(thread))
  assert(vim.api.nvim_buf_get_lines(drawer, 1, 2, false)[1]:find("2/2", 1, true), "latest turn history position")
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  vim.api.nvim_feedkeys("=", "x", false)
  vim.wait(100)
  local expanded = table.concat(vim.api.nvim_buf_get_lines(drawer, 0, -1, false), "\n")
  assert(expanded:find("@@", 1, true), "inline diff hunk is expanded")
  assert(expanded:find("-local value = 1", 1, true), "inline deleted line")
  assert(expanded:find("+local value = 2", 1, true), "inline added line")
  local inline_marks = vim.api.nvim_buf_get_extmarks(
    drawer,
    vim.api.nvim_get_namespaces().LazyAgentACPChanges,
    0,
    -1,
    { details = true }
  )
  local inline_groups = {}
  for _, mark in ipairs(inline_marks) do
    local group = mark[4] and mark[4].hl_group
    if group then inline_groups[group] = true end
  end
  assert(inline_groups.LazyAgentACPChangesDiffDelete, "inline deleted background highlight")
  assert(inline_groups.LazyAgentACPChangesDiffAdd, "inline added background highlight")
  assert(inline_groups.LazyAgentACPChangesDiffAddText, "inline word-level highlight")
  assert_equal(vim.fn.maparg("=", "n", false, true).desc, "Toggle LazyAgent ACP inline diff", "inline diff mapping")
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  vim.api.nvim_feedkeys("=", "x", false)
  vim.wait(100)
  assert(not table.concat(vim.api.nvim_buf_get_lines(drawer, 0, -1, false), "\n"):find("@@", 1, true), "inline diff closes")
  vim.api.nvim_feedkeys("[t", "x", false)
  vim.wait(100)
  assert(vim.api.nvim_buf_get_lines(drawer, 1, 2, false)[1]:find("thread%-1:1"), "previous turn mapping")
  assert(vim.api.nvim_buf_get_lines(drawer, 1, 2, false)[1]:find("1/2", 1, true), "previous turn history position")
  assert_equal(vim.fn.maparg("a", "n", false, true).desc, "Approve LazyAgent ACP file change", "approve mapping")
  assert_equal(vim.fn.maparg("A", "n", false, true).desc, "Approve all LazyAgent ACP changes", "approve all mapping")
  assert_equal(vim.fn.maparg("o", "n", false, true).desc, "Open all LazyAgent ACP changes", "open all mapping")
  assert_equal(vim.fn.maparg("k", "n", false, true).buffer or 0, 0, "k remains normal movement")
  vim.api.nvim_buf_delete(drawer, { force = true })

  local missing_change = { operation = "modified", path = "lua/missing.lua", before_blob = "before-a" }
  local notification
  local previous_notify = vim.notify
  vim.notify = function(message) notification = message end
  assert_equal(review.open_change(thread, turn, missing_change, 1), false, "missing modified side is not opened as empty")
  vim.notify = previous_notify
  assert(tostring(notification):find("after blob is unavailable", 1, true), "missing modified blob is reported explicitly")
end

return M
