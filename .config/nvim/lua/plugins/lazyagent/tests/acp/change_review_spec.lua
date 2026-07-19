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
            { operation = "modified", path = "lua/a.lua", decision = "kept" },
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
    "",
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
    read_blob = function()
      return ""
    end,
  })
  local drawer = assert(review.open(thread))
  assert(vim.api.nvim_buf_get_lines(drawer, 1, 2, false)[1]:find("2/2", 1, true), "latest turn history position")
  vim.api.nvim_feedkeys("[t", "x", false)
  vim.wait(100)
  assert(vim.api.nvim_buf_get_lines(drawer, 1, 2, false)[1]:find("thread%-1:1"), "previous turn mapping")
  assert(vim.api.nvim_buf_get_lines(drawer, 1, 2, false)[1]:find("1/2", 1, true), "previous turn history position")
  assert_equal(vim.fn.maparg("a", "n", false, true).desc, "Approve LazyAgent ACP file change", "approve mapping")
  assert_equal(vim.fn.maparg("A", "n", false, true).desc, "Approve all LazyAgent ACP changes", "approve all mapping")
  assert_equal(vim.fn.maparg("o", "n", false, true).desc, "Open all LazyAgent ACP changes", "open all mapping")
  assert_equal(vim.fn.maparg("k", "n", false, true).buffer or 0, 0, "k remains normal movement")
  vim.api.nvim_buf_delete(drawer, { force = true })
end

return M
