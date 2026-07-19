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
    "`i` next diff  `o` toggle inline  `<CR>` open file  `d` diff tab",
    "M  lua/a.lua [approved]",
    "R  old.bin -> new.bin [binary] [rejected]",
  }, "changed files drawer")
  local _, _, _, target_lines = ChangeReview.drawer_content(thread, turn, nil, nil, {
    [1] = { "@@ -10,2 +20,3 @@", " old", "-gone", "+new", " tail" },
  })
  assert_equal(target_lines[5], 20, "hunk header targets after start line")
  assert_equal(target_lines[6], 20, "context line targets current after line")
  assert_equal(target_lines[7], 21, "deleted line targets next surviving after line")
  assert_equal(target_lines[8], 21, "added line targets its after line")
  assert_equal(target_lines[9], 22, "following context advances after line")

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
      local fillers = table.concat(vim.tbl_map(function(index)
        return "local filler" .. index .. " = " .. index
      end, { 1, 2, 3, 4, 5, 6, 7, 8 }), "\n")
      return ({
        ["before-a"] = "local value = 1\n" .. fillers .. "\nreturn value\n",
        ["after-a"] = "local value = 2\n" .. fillers .. "\nreturn value + 1\n",
      })[ref] or ""
    end,
  })
  local drawer = assert(review.open(thread))
  local drawer_position = vim.api.nvim_win_get_position(0)
  assert(drawer_position[1] > 0, "changes drawer opens in a bottom split")
  assert(vim.api.nvim_buf_get_lines(drawer, 1, 2, false)[1]:find("2/2", 1, true), "latest turn history position")
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  vim.api.nvim_feedkeys("i", "x", false)
  vim.wait(100)
  assert((vim.api.nvim_get_current_line() or ""):match("^@@"), "i opens inline diff and jumps to its first hunk")
  local first_hunk_row = vim.api.nvim_win_get_cursor(0)[1]
  vim.api.nvim_feedkeys("i", "x", false)
  vim.wait(100)
  assert((vim.api.nvim_get_current_line() or ""):match("^@@"), "i moves to the next expanded hunk")
  assert(vim.api.nvim_win_get_cursor(0)[1] > first_hunk_row, "next hunk is below the first")
  vim.api.nvim_feedkeys("i", "x", false)
  vim.wait(100)
  assert((vim.api.nvim_get_current_line() or ""):match("^R  old%.bin"), "i stops on the next file row")
  assert(not table.concat(vim.api.nvim_buf_get_lines(drawer, 0, -1, false), "\n"):find(
    "Binary change: inline text diff is unavailable.", 1, true
  ), "moving to the next file does not expand it")
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
  local syntax_group
  for _, mark in ipairs(inline_marks) do
    local group = mark[4] and mark[4].hl_group
    if group then
      inline_groups[group] = true
      if group:match("^@.+%.lua$") then syntax_group = group end
    end
  end
  assert(inline_groups.LazyAgentACPChangesDiffDelete, "inline deleted background highlight")
  assert(inline_groups.LazyAgentACPChangesDiffAdd, "inline added background highlight")
  assert(inline_groups.LazyAgentACPChangesDiffAddText, "inline word-level highlight")
  assert(syntax_group, "inline Lua code receives Tree-sitter syntax highlights")
  assert_equal(vim.fn.maparg("i", "n", false, true).desc, "Open and jump to next LazyAgent ACP diff", "next diff mapping")
  assert_equal(vim.fn.maparg("o", "n", false, true).desc, "Toggle LazyAgent ACP inline diff", "inline diff mapping")
  assert_equal(vim.fn.maparg("=", "n", false, true).desc, "Toggle LazyAgent ACP inline diff", "inline diff mapping")
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  vim.api.nvim_feedkeys("o", "x", false)
  vim.wait(100)
  assert(not table.concat(vim.api.nvim_buf_get_lines(drawer, 0, -1, false), "\n"):find("@@", 1, true), "inline diff closes")
  vim.api.nvim_feedkeys("[t", "x", false)
  vim.wait(100)
  assert(vim.api.nvim_buf_get_lines(drawer, 1, 2, false)[1]:find("thread%-1:1"), "previous turn mapping")
  assert(vim.api.nvim_buf_get_lines(drawer, 1, 2, false)[1]:find("1/2", 1, true), "previous turn history position")
  assert_equal(vim.fn.maparg("a", "n", false, true).desc, "Approve LazyAgent ACP file change", "approve mapping")
  assert_equal(vim.fn.maparg("A", "n", false, true).desc, "Approve all LazyAgent ACP changes", "approve all mapping")
  assert_equal(vim.fn.maparg("<CR>", "n", false, true).desc, "Open LazyAgent ACP changed file", "open file mapping")
  assert_equal(vim.fn.maparg("d", "n", false, true).desc, "Open LazyAgent ACP diff tab", "diff tab mapping")
  assert_equal(vim.fn.maparg("k", "n", false, true).buffer or 0, 0, "k remains normal movement")

  vim.api.nvim_feedkeys("]t", "x", false)
  vim.wait(100)
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  vim.api.nvim_feedkeys("o", "x", false)
  vim.wait(100)
  local plus_row
  for row, line in ipairs(vim.api.nvim_buf_get_lines(drawer, 0, -1, false)) do
    if line == "+local value = 2" then plus_row = row break end
  end
  local opened_line
  review.open_file = function(_, _, _, line)
    opened_line = line
    return true
  end
  vim.api.nvim_win_set_cursor(0, { assert(plus_row), 0 })
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
  vim.wait(100)
  assert_equal(opened_line, 1, "enter opens file at corresponding after line")

  local tabs_before = vim.fn.tabpagenr("$")
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  vim.api.nvim_feedkeys("d", "x", false)
  vim.wait(100)
  assert_equal(vim.fn.tabpagenr("$"), tabs_before + 1, "diff opens in a dedicated tab")
  assert_equal(#vim.api.nvim_tabpage_list_wins(0), 2, "diff tab has before and after windows")
  assert_equal(vim.wo.diff, true, "after side has diff mode enabled")
  assert_equal(vim.fn.maparg("q", "n", false, true).desc, "Close LazyAgent ACP diff tab", "after diff close mapping")
  vim.cmd("wincmd h")
  assert_equal(vim.wo.diff, true, "before side has diff mode enabled")
  assert_equal(vim.fn.maparg("q", "n", false, true).desc, "Close LazyAgent ACP diff tab", "before diff close mapping")
  vim.api.nvim_feedkeys("q", "x", false)
  vim.wait(100)
  assert_equal(vim.fn.tabpagenr("$"), tabs_before, "q closes the whole diff tab")
  assert_equal(vim.api.nvim_get_current_buf(), drawer, "q returns to the changes drawer")
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
