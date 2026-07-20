local M = {}

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run()
  local Feedback = require("lazyagent.acp.review_feedback")
  local prompt, ids, has_feedback = Feedback.build_prompt({
    turn_id = "thread-1:2",
    changes = {
      { path = "README.md", decision = "kept" },
      { path = "lua/a.lua", hunks = { {
        index = 1, decision = "rejected",
        before_start = 3, before_count = 1, after_start = 3, after_count = 2,
      } } },
    },
    annotations = {
      {
        id = "user-1", kind = "review", path = "lua/a.lua", rationale = "Keep the API but rename this value.",
        target = { start_line = 3, end_line = 4 }, author = { type = "user", name = "User" },
      },
      { id = "agent-1", kind = "review", rationale = "Agent-generated note", author = { type = "agent" } },
    },
  })
  assert_equal(has_feedback, true, "review prompt detects decisions and user notes")
  assert(prompt:find("Approved: README.md", 1, true), "review prompt includes file decision")
  assert(prompt:find("Rejected hunk: lua/a.lua @@ -3,1 +3,2 @@", 1, true), "review prompt includes hunk decision")
  assert(prompt:find("lua/a.lua:3-4", 1, true), "review prompt includes note target")
  assert(prompt:find("Keep the API", 1, true), "review prompt includes user note")
  assert(not prompt:find("Agent-generated note", 1, true), "review prompt excludes agent annotations")
  assert_equal(ids, { "user-1" }, "only sent user note ids are consumed")

  local editor_buf, editor_win = Feedback.open_editor({
    text = prompt,
    on_submit = function() return true end,
    submit_desc = "Send review fixture",
  })
  assert_equal(vim.b[editor_buf].lazyagent_review_editor, true, "review editor marker")
  assert_equal(vim.api.nvim_win_is_valid(editor_win), true, "review editor window")
  assert_equal(vim.fn.maparg("<C-Space>", "n", false, true).desc, "Send review fixture", "review editor submit mapping")
  vim.api.nvim_win_close(editor_win, true)
end

return M
