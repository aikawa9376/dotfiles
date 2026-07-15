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
        { turn_id = "thread-1:1", changes = {} },
        {
          turn_id = "thread-1:2",
          changes = {
            { operation = "modified", path = "lua/a.lua" },
            { operation = "moved", previous_path = "old.bin", path = "new.bin", binary = true },
          },
        },
      },
    },
  }
  local turn = assert(ChangeReview.latest_turn(thread))
  assert_equal(turn.turn_id, "thread-1:2", "latest changed turn")
  assert_equal(ChangeReview.drawer_lines(thread, turn), {
    "LazyAgent ACP Changes — Review fixture",
    "Turn thread-1:2 · 2 file(s)",
    "",
    "M  lua/a.lua",
    "R  old.bin -> new.bin [binary]",
  }, "changed files drawer")
end

return M
