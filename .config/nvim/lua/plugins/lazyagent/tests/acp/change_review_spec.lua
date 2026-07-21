local M = {}

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run()
  local ChangeReview = require("lazyagent.acp.change_review")
  local ReviewAnnotations = require("lazyagent.acp.review_annotations")
  local thread = {
    thread_id = "thread-1",
    title = "Review fixture",
    change_journal = {
      turns = {
        {
          turn_id = "thread-1:1",
          user_input = "Add the older file",
          changes = {
            { operation = "added", path = "lua/older.lua" },
          },
        },
        {
          turn_id = "thread-1:2",
          user_input = "Update the return value\nwhile keeping compatibility",
          annotations = {
            { kind = "explanation", summary = "Turn summary", rationale = "Changed the return value.\nKept compatibility." },
            {
              kind = "review", path = "lua/a.lua", summary = "Check this value",
              target = { start_line = 1, end_line = 1, blob_hash = "after-hash" },
            },
            {
              kind = "review", label = "should", path = "lua/a.lua", summary = "Check surrounding code",
              target = { start_line = 10, end_line = 10, blob_hash = "after-hash" },
            },
          },
          changes = {
            {
              operation = "modified", path = "lua/a.lua", decision = "kept",
              before_blob = "before-a", after_blob = { hash = "after-hash", ref = "after-a" },
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
  local stale = ReviewAnnotations.for_change({ annotations = { {
    path = "lua/a.lua", summary = "Old note", target = { blob_hash = "old-hash" },
  } } }, { path = "lua/a.lua", after_blob = { hash = "new-hash" } })
  assert_equal(stale[1].outdated, true, "blob changes mark annotations outdated")
  local explanation = ReviewAnnotations.latest_explanation({
    { kind = "assistant", body = "old response" },
    { kind = "user", body = "new prompt" },
    { kind = "assistant", body_ref = { value = "new response" }, summary = "Done" },
  }, 1, function(item) return item.body_ref and item.body_ref.value or item.body end, { name = "Codex" })
  assert_equal(explanation.rationale, "new response", "latest turn assistant response becomes an explanation")
  assert_equal(explanation.author.name, "Codex", "turn explanation retains its author")
  assert_equal(ReviewAnnotations.markdown(ReviewAnnotations.for_turn(turn)), {
    "## Explanation", "", "Changed the return value.", "Kept compatibility.",
  }, "explanation omits the lossy summary and keeps the multiline final answer")
  assert_equal(ChangeReview.drawer_lines(thread, turn), {
    "LazyAgent ACP Changes — Update the return value while keeping compatibility",
    "Turn thread-1:2 · 2 file(s) · 📝 final",
    "`?` actions  `K` note/final  `c` comment  `S` send review  `i` next diff  `o` toggle inline  `<CR>` open file  `d` diff tab  `v` comments",
    "",
    "M  lua/a.lua [approved] 💬2",
    "R  old.bin -> new.bin [binary] [rejected]",
  }, "changed files drawer")
  local _, _, _, target_lines = ChangeReview.drawer_content(thread, turn, nil, nil, {
    [1] = { "@@ -10,2 +20,3 @@", " old", "-gone", "+new", " tail" },
  })
  assert_equal(target_lines[6], 20, "hunk header targets after start line")
  assert_equal(target_lines[7], 20, "context line targets current after line")
  assert_equal(target_lines[8], 21, "deleted line targets next surviving after line")
  assert_equal(target_lines[9], 21, "added line targets its after line")
  assert_equal(target_lines[10], 22, "following context advances after line")
  assert_equal(ChangeReview.append_review_context(
    { "@@ -1 +1 @@", "-old", "+line 1" },
    table.concat(vim.tbl_map(function(index) return "line " .. index end, vim.fn.range(1, 14)), "\n") .. "\n",
    {
      { target = { side = "after", start_line = 1, end_line = 1 } },
      { target = { side = "after", start_line = 8, end_line = 8 } },
      { target = { side = "after", start_line = 10, end_line = 10 } },
      { target = { side = "after", start_line = 99, end_line = 99 } },
    },
    2
  ), {
    "@@ -1 +1 @@", "-old", "+line 1",
    ":: review context +6,7 ::",
    " line 6", " line 7", " line 8", " line 9", " line 10", " line 11", " line 12",
  }, "hunk-external review targets add merged after-side context")

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
  assert_equal(vim.api.nvim_get_hl(0, { name = "LazyAgentACPChangesDiffAdd", link = true }).link,
    "FugitiveExtAdd", "Changes always uses fugitive-extension add colors")
  assert_equal(vim.api.nvim_get_hl(0, { name = "LazyAgentACPChangesNote", link = true }).link,
    "GitSignsChange", "change notes follow fugitive status colors")
  vim.api.nvim_buf_delete(bufnr, { force = true })

  local utf_turn = {
    turn_id = "utf:1",
    changes = { { operation = "modified", path = "notes.txt" } },
  }
  local utf_lines, utf_rows, utf_changes, utf_targets = ChangeReview.drawer_content(
    { thread_id = "utf", title = "UTF-8" },
    utf_turn,
    nil,
    nil,
    { [1] = { "@@ -1 +1 @@", "-あ", "+い" } }
  )
  local utf_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(utf_bufnr, 0, -1, false, utf_lines)
  ChangeReview.apply_drawer_highlights(utf_bufnr, utf_turn, utf_rows, utf_changes, utf_targets)
  local utf_marks = vim.api.nvim_buf_get_extmarks(
    utf_bufnr,
    vim.api.nvim_get_namespaces().LazyAgentACPChanges,
    0,
    -1,
    { details = true }
  )
  local utf_spans = {}
  for _, mark in ipairs(utf_marks) do
    local group = mark[4] and mark[4].hl_group
    if group == "LazyAgentACPChangesDiffDeleteText" or group == "LazyAgentACPChangesDiffAddText" then
      utf_spans[group] = { start_col = mark[3], end_col = mark[4].end_col }
    end
  end
  assert_equal(utf_spans.LazyAgentACPChangesDiffDeleteText, { start_col = 1, end_col = 4 },
    "UTF-8 deleted highlight starts at a character boundary")
  assert_equal(utf_spans.LazyAgentACPChangesDiffAddText, { start_col = 1, end_col = 4 },
    "UTF-8 added highlight starts at a character boundary")
  vim.api.nvim_buf_delete(utf_bufnr, { force = true })

  local live_thread
  local get_thread_calls = 0
  local review = ChangeReview.new({
    read_blob = function(ref)
      local fillers = table.concat(vim.tbl_map(function(index)
        return "local filler" .. index .. " = " .. index
      end, vim.fn.range(1, 20)), "\n")
      if type(ref) == "table" then ref = ref.ref end
      return ({
        ["before-a"] = "local value = 1\n" .. fillers .. "\nreturn value\n",
        ["after-a"] = "local value = 2\n" .. fillers .. "\nreturn value + 1\n",
      })[ref] or ""
    end,
    get_thread = function()
      get_thread_calls = get_thread_calls + 1
      return live_thread
    end,
    checkpoint = function() error("active turn checkpoint must be blocked") end,
    branch = function() error("active turn branch must be blocked") end,
  })
  local drawer = assert(review.open(thread))
  local drawer_position = vim.api.nvim_win_get_position(0)
  assert(drawer_position[1] > 0, "changes drawer opens in a bottom split")
  assert_equal(vim.wo.number, false, "changes drawer hides absolute line numbers like Fugitive status")
  assert_equal(vim.wo.relativenumber, false, "changes drawer hides relative line numbers like Fugitive status")
  assert_equal(vim.wo.cursorline, false, "changes drawer avoids an inherited blue cursor-line background")
  assert_equal(review.open(thread), drawer, "reopening a thread reuses its changes buffer")
  assert_equal(#vim.fn.win_findbuf(drawer), 1, "reopening a visible changes drawer does not duplicate its window")
  assert_equal(vim.api.nvim_buf_get_lines(drawer, 0, 1, false)[1],
    "LazyAgent ACP Changes — Update the return value while keeping compatibility",
    "changes drawer title uses the selected turn user input")
  assert(vim.api.nvim_buf_get_lines(drawer, 1, 2, false)[1]:find("2/2", 1, true), "latest turn history position")
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  local menu_items, menu_opts, menu_callback
  local original_select = vim.ui.select
  vim.ui.select = function(items, opts, callback)
    menu_items, menu_opts, menu_callback = items, opts, callback
  end
  vim.cmd("normal ?")
  vim.ui.select = original_select
  assert_equal(menu_opts.kind, "lazyagent-acp-actions", "changes action menu uses compact cursor UI")
  assert_equal(menu_items[1].key, "K", "changes action menu lists notes first")
  assert_equal(vim.fn.maparg("?", "n", false, true).desc, "Open LazyAgent ACP changes action menu", "changes menu mapping")
  local next_diff_action
  for _, item in ipairs(menu_items) do if item.key == "i" then next_diff_action = item end end
  vim.cmd("aboveleft new")
  local unrelated_winid = vim.api.nvim_get_current_win()
  menu_callback(next_diff_action)
  vim.wait(100)
  assert_equal(vim.api.nvim_get_current_buf(), drawer, "changes menu restores drawer context before executing an action")
  vim.api.nvim_win_close(unrelated_winid, true)
  assert((vim.api.nvim_get_current_line() or ""):match("^@@"), "menu executes inline diff action")
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
  assert(expanded:find(":: review context +7,7 ::", 1, true), "hunk-external finding adds review context")
  assert(expanded:find(" local filler9 = 9", 1, true), "review context includes the finding target")
  local inline_marks = vim.api.nvim_buf_get_extmarks(
    drawer,
    vim.api.nvim_get_namespaces().LazyAgentACPChanges,
    0,
    -1,
    { details = true }
  )
  local inline_groups = {}
  local inline_priorities = {}
  local syntax_group
  local context_badge
  for _, mark in ipairs(inline_marks) do
    local group = mark[4] and mark[4].hl_group
    if group then
      inline_groups[group] = true
      inline_priorities[group] = math.max(inline_priorities[group] or 0, tonumber(mark[4].priority) or 0)
      if group:match("^@.+%.lua$") then syntax_group = group end
    end
    local virt_text = mark[4] and mark[4].virt_text or {}
    for _, chunk in ipairs(virt_text) do
      if tostring(chunk[1]):find("💬[should]", 1, true) then context_badge = true end
    end
  end
  assert(inline_groups.LazyAgentACPChangesDiffDelete, "inline deleted background highlight")
  assert(inline_groups.LazyAgentACPChangesDiffAdd, "inline added background highlight")
  assert(inline_groups.LazyAgentACPChangesDiffAddText, "inline word-level highlight")
  assert(inline_groups.diffLine, "hunk header directly uses Fugitive-style diffLine highlight")
  assert(inline_groups.LazyAgentACPChangesContext, "review context header is distinguished from diff hunks")
  assert(context_badge, "hunk-external finding is shown on its after-side context line")
  assert(syntax_group, "inline Lua code receives Tree-sitter syntax highlights")
  assert_equal(inline_priorities.LazyAgentACPChangesDiffAdd, 200, "inline background uses Fugitive priority")
  assert_equal(inline_priorities.LazyAgentACPChangesDiffAddText, 360, "inline word diff wins over syntax like Fugitive")
  assert_equal(vim.fn.maparg("i", "n", false, true).desc, "Open and jump to next LazyAgent ACP diff", "next diff mapping")
  assert_equal(vim.fn.maparg("o", "n", false, true).desc, "Toggle LazyAgent ACP inline diff", "inline diff mapping")
  assert_equal(vim.fn.maparg("K", "n", false, true).desc, "Show LazyAgent ACP change note", "note mapping")
  assert_equal(vim.fn.maparg("c", "n", false, true).desc, "Add LazyAgent ACP review note", "add review note mapping")
  assert_equal(vim.fn.maparg("S", "n", false, true).desc, "Send LazyAgent ACP review feedback", "send review mapping")
  assert_equal(vim.fn.maparg("]n", "n", false, true).desc, "Next LazyAgent ACP change note", "next note mapping")
  assert_equal(vim.fn.maparg("=", "n", false, true).desc, "Toggle LazyAgent ACP inline diff", "inline diff mapping")
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.api.nvim_feedkeys("K", "x", false)
  vim.wait(100)
  assert_equal(vim.bo.filetype, "markdown", "K on the turn header opens the final answer")
  assert(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("Changed the return value", 1, true),
    "final answer body")
  vim.api.nvim_feedkeys("q", "x", false)
  vim.wait(100)
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  vim.api.nvim_feedkeys("K", "x", false)
  vim.wait(100)
  assert_equal(vim.bo.filetype, "markdown", "K opens a markdown note float")
  assert(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("Check this value", 1, true), "note body")
  vim.api.nvim_feedkeys("q", "x", false)
  vim.wait(100)
  vim.api.nvim_feedkeys("o", "x", false)
  vim.wait(100)
  assert(not table.concat(vim.api.nvim_buf_get_lines(drawer, 0, -1, false), "\n"):find("@@", 1, true), "inline diff closes")
  vim.api.nvim_feedkeys("[t", "x", false)
  vim.wait(100)
  assert_equal(vim.api.nvim_buf_get_lines(drawer, 0, 1, false)[1],
    "LazyAgent ACP Changes — Add the older file", "previous turn title follows its user input")
  assert(vim.api.nvim_buf_get_lines(drawer, 1, 2, false)[1]:find("thread%-1:1"), "previous turn mapping")
  assert(vim.api.nvim_buf_get_lines(drawer, 1, 2, false)[1]:find("1/2", 1, true), "previous turn history position")
  assert_equal(vim.fn.maparg("a", "n", false, true).desc, "Approve LazyAgent ACP file change", "approve mapping")
  assert_equal(vim.fn.maparg("A", "n", false, true).desc, "Approve all LazyAgent ACP changes", "approve all mapping")
  assert_equal(vim.fn.maparg("<CR>", "n", false, true).desc, "Open LazyAgent ACP changed file", "open file mapping")
  assert_equal(vim.fn.maparg("d", "n", false, true).desc, "Open LazyAgent ACP diff tab", "diff tab mapping")
  assert_equal(vim.fn.maparg("v", "n", false, true).desc,
    "Toggle LazyAgent ACP review comments in file", "actual file comment mapping")
  assert_equal(vim.fn.maparg("k", "n", false, true).buffer or 0, 0, "k remains normal movement")

  vim.api.nvim_feedkeys("]t", "x", false)
  vim.wait(100)
  assert_equal(vim.api.nvim_buf_get_lines(drawer, 0, 1, false)[1],
    "LazyAgent ACP Changes — Update the return value while keeping compatibility",
    "next turn restores its user input title")
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
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
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  vim.api.nvim_feedkeys("d", "x", false)
  vim.wait(100)
  assert_equal(vim.fn.tabpagenr("$"), tabs_before + 1, "diff opens in a dedicated tab")
  assert_equal(#vim.api.nvim_tabpage_list_wins(0), 2, "diff tab has before and after windows")
  assert_equal(vim.wo.diff, true, "after side has diff mode enabled")
  assert_equal(vim.fn.maparg("q", "n", false, true).desc, "Close LazyAgent ACP diff tab", "after diff close mapping")
  local diff_comment_marks = vim.api.nvim_buf_get_extmarks(
    0,
    vim.api.nvim_get_namespaces().LazyAgentACPReviewComments,
    0,
    -1,
    { details = true }
  )
  assert_equal(#diff_comment_marks, 2, "after diff buffer shows review comments")
  local diff_comment_text = vim.inspect(diff_comment_marks[1][4].virt_lines)
    .. vim.inspect(diff_comment_marks[2][4].virt_lines)
  assert(diff_comment_text:find("Check this value", 1, true), "diff comment includes its summary")
  assert(diff_comment_text:find("[should]", 1, true), "diff comment includes its label")
  vim.cmd("wincmd h")
  assert_equal(vim.wo.diff, true, "before side has diff mode enabled")
  assert_equal(vim.fn.maparg("q", "n", false, true).desc, "Close LazyAgent ACP diff tab", "before diff close mapping")
  vim.api.nvim_feedkeys("q", "x", false)
  vim.wait(100)
  assert_equal(vim.fn.tabpagenr("$"), tabs_before, "q closes the whole diff tab")
  assert_equal(vim.api.nvim_get_current_buf(), drawer, "q returns to the changes drawer")

  local file_root = vim.fn.tempname()
  vim.fn.mkdir(file_root .. "/lua", "p")
  local actual_lines = { "local value = 2" }
  for index = 1, 20 do actual_lines[#actual_lines + 1] = "local filler" .. index .. " = " .. index end
  actual_lines[#actual_lines + 1] = "return value + 1"
  vim.fn.writefile(actual_lines, file_root .. "/lua/a.lua")
  thread.cwd = file_root
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  vim.api.nvim_feedkeys("v", "x", false)
  vim.wait(100)
  assert_equal(vim.api.nvim_buf_get_name(0), file_root .. "/lua/a.lua", "v opens the actual changed file")
  local actual_marks = vim.api.nvim_buf_get_extmarks(
    0,
    vim.api.nvim_get_namespaces().LazyAgentACPReviewComments,
    0,
    -1,
    { details = true }
  )
  assert_equal(#actual_marks, 2, "actual file receives review comments")
  assert(vim.inspect(actual_marks):find("target differs from the reviewed snapshot", 1, true),
    "diverged actual file warns that review line targets may be stale")
  assert_equal(review.open(thread), drawer, "review drawer reopens after showing actual comments")
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  vim.api.nvim_feedkeys("v", "x", false)
  vim.wait(100)
  assert_equal(#vim.api.nvim_buf_get_extmarks(
    0, vim.api.nvim_get_namespaces().LazyAgentACPReviewComments, 0, -1, {}
  ), 0, "v toggles actual file comments off")
  vim.api.nvim_buf_delete(0, { force = true })
  assert_equal(review.open(thread), drawer, "review drawer reopens after hiding actual comments")
  vim.fn.delete(file_root, "rf")
  thread.cwd = nil

  local binary_tabs_before = vim.fn.tabpagenr("$")
  assert_equal(review.open_change(thread, turn, turn.changes[2], 2), true, "open binary change")
  local first_binary_name = vim.api.nvim_buf_get_name(0)
  assert_equal(review.open_change(thread, turn, turn.changes[2], 2), true, "reopen binary change")
  local second_binary_name = vim.api.nvim_buf_get_name(0)
  assert(first_binary_name ~= second_binary_name, "repeated binary reviews use collision-free scratch buffers")
  assert_equal(vim.fn.tabpagenr("$"), binary_tabs_before + 2, "binary reviews open independent tabs")
  vim.cmd("tabclose")
  vim.cmd("tabclose")
  assert_equal(vim.api.nvim_get_current_buf(), drawer, "binary review tabs return to the changes drawer")

  live_thread = vim.deepcopy(thread)
  live_thread.change_journal.turns[#live_thread.change_journal.turns + 1] = {
    turn_id = "thread-1:3", state = "active",
    user_input = "Add the live preview",
    changes = { { operation = "added", path = "lua/live.lua", after_blob = "after-a" } },
  }
  vim.api.nvim_exec_autocmds("User", {
    pattern = "LazyAgentChangeJournal", data = { thread_id = "thread-1", turn_id = "thread-1:3", state = "active" },
  })
  vim.wait(100)
  assert(vim.api.nvim_buf_get_lines(drawer, 1, 2, false)[1]:find("live", 1, true),
    "open Changes drawer follows active turn updates")
  assert_equal(vim.api.nvim_buf_get_lines(drawer, 0, 1, false)[1],
    "LazyAgent ACP Changes — Add the live preview", "live turn title follows its user input")
  assert(table.concat(vim.api.nvim_buf_get_lines(drawer, 0, -1, false), "\n"):find("lua/live.lua", 1, true),
    "realtime drawer renders newly changed files")
  vim.ui.select = function(items, opts, callback)
    menu_items, menu_opts, menu_callback = items, opts, callback
  end
  vim.cmd("normal ?")
  vim.ui.select = original_select
  assert_equal(menu_items[#menu_items].key, "q", "changes action menu lists close action")
  menu_callback(menu_items[#menu_items])
  assert_equal(vim.fn.bufwinid(drawer), -1, "changes action menu executes close action")

  local calls_while_visible = get_thread_calls
  vim.api.nvim_exec_autocmds("User", {
    pattern = "LazyAgentChangeJournal", data = { thread_id = "thread-1", turn_id = "thread-1:3", state = "active" },
  })
  vim.wait(100)
  assert_equal(get_thread_calls, calls_while_visible, "hidden changes drawer defers live refresh")
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, drawer)
  vim.wait(100)
  assert_equal(get_thread_calls, calls_while_visible + 1, "reopened changes drawer catches up once")
  vim.cmd("close")
  vim.api.nvim_buf_delete(drawer, { force = true })

  local missing_change = { operation = "modified", path = "lua/missing.lua", before_blob = "before-a" }
  local notification
  local previous_notify = vim.notify
  vim.notify = function(message) notification = message end
  assert_equal(review.open_change(thread, turn, missing_change, 1), false, "missing modified side is not opened as empty")
  vim.notify = previous_notify
  assert(tostring(notification):find("after blob is unavailable", 1, true), "missing modified blob is reported explicitly")

  local empty_thread = {
    thread_id = "thread-empty",
    title = "Empty active turn",
    change_journal = { turns = {
      { turn_id = "thread-empty:1", changes = { { operation = "added", path = "old.lua", after_blob = "after-a" } } },
      { turn_id = "thread-empty:2", state = "active" },
    } },
  }
  local empty_drawer = assert(review.open(empty_thread))
  assert_equal(vim.api.nvim_buf_get_lines(empty_drawer, 0, 1, false)[1],
    "LazyAgent ACP Changes — Empty active turn", "legacy turns fall back to the thread title")
  assert(vim.api.nvim_buf_get_lines(empty_drawer, 1, 2, false)[1]:find("0 file(s)", 1, true),
    "active turn can be displayed before its first file change")
  local active_select = vim.ui.select
  vim.ui.select = function(items, _, callback) callback(items[#items]) end
  for _, key in ipairs({ "a", "A", "r", "R", "h", "u", "U", "b" }) do
    local mapping = vim.fn.maparg(key, "n", false, true)
    assert(type(mapping.callback) == "function", "empty turn keeps " .. key .. " mapping")
    local ok, err = pcall(mapping.callback)
    assert(ok, string.format("%s is a no-op on an empty active turn: %s", key, tostring(err)))
  end
  vim.ui.select = active_select
  vim.cmd("close")
  vim.api.nvim_buf_delete(empty_drawer, { force = true })
end

return M
