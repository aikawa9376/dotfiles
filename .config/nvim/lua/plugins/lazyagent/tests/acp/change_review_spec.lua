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
          changes = {
            { operation = "added", path = "lua/older.lua" },
          },
        },
        {
          turn_id = "thread-1:2",
          annotations = {
            { kind = "explanation", summary = "Turn summary", rationale = "Changed the return value.\nKept compatibility." },
            {
              kind = "review", path = "lua/a.lua", summary = "Check this value",
              target = { start_line = 1, end_line = 1, blob_hash = "after-hash" },
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
    "LazyAgent ACP Changes — Review fixture",
    "Turn thread-1:2 · 2 file(s) · 📝 final",
    "`?` actions  `K` note/final  `i` next diff  `o` toggle inline  `<CR>` open file  `d` diff tab",
    "",
    "M  lua/a.lua [approved] 💬1",
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

  local live_thread
  local review = ChangeReview.new({
    read_blob = function(ref)
      local fillers = table.concat(vim.tbl_map(function(index)
        return "local filler" .. index .. " = " .. index
      end, { 1, 2, 3, 4, 5, 6, 7, 8 }), "\n")
      if type(ref) == "table" then ref = ref.ref end
      return ({
        ["before-a"] = "local value = 1\n" .. fillers .. "\nreturn value\n",
        ["after-a"] = "local value = 2\n" .. fillers .. "\nreturn value + 1\n",
      })[ref] or ""
    end,
    get_thread = function() return live_thread end,
  })
  local drawer = assert(review.open(thread))
  local drawer_position = vim.api.nvim_win_get_position(0)
  assert(drawer_position[1] > 0, "changes drawer opens in a bottom split")
  assert_equal(vim.wo.number, false, "changes drawer hides absolute line numbers like Fugitive status")
  assert_equal(vim.wo.relativenumber, false, "changes drawer hides relative line numbers like Fugitive status")
  assert_equal(vim.wo.cursorline, false, "changes drawer avoids an inherited blue cursor-line background")
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
  menu_callback(menu_items[4])
  vim.wait(100)
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
  for _, mark in ipairs(inline_marks) do
    local group = mark[4] and mark[4].hl_group
    if group then
      inline_groups[group] = true
      inline_priorities[group] = math.max(inline_priorities[group] or 0, tonumber(mark[4].priority) or 0)
      if group:match("^@.+%.lua$") then syntax_group = group end
    end
  end
  assert(inline_groups.LazyAgentACPChangesDiffDelete, "inline deleted background highlight")
  assert(inline_groups.LazyAgentACPChangesDiffAdd, "inline added background highlight")
  assert(inline_groups.LazyAgentACPChangesDiffAddText, "inline word-level highlight")
  assert(inline_groups.diffLine, "hunk header directly uses Fugitive-style diffLine highlight")
  assert(syntax_group, "inline Lua code receives Tree-sitter syntax highlights")
  assert_equal(inline_priorities.LazyAgentACPChangesDiffAdd, 200, "inline background uses Fugitive priority")
  assert_equal(inline_priorities.LazyAgentACPChangesDiffAddText, 360, "inline word diff wins over syntax like Fugitive")
  assert_equal(vim.fn.maparg("i", "n", false, true).desc, "Open and jump to next LazyAgent ACP diff", "next diff mapping")
  assert_equal(vim.fn.maparg("o", "n", false, true).desc, "Toggle LazyAgent ACP inline diff", "inline diff mapping")
  assert_equal(vim.fn.maparg("K", "n", false, true).desc, "Show LazyAgent ACP change note", "note mapping")
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
  assert(vim.api.nvim_buf_get_lines(drawer, 1, 2, false)[1]:find("thread%-1:1"), "previous turn mapping")
  assert(vim.api.nvim_buf_get_lines(drawer, 1, 2, false)[1]:find("1/2", 1, true), "previous turn history position")
  assert_equal(vim.fn.maparg("a", "n", false, true).desc, "Approve LazyAgent ACP file change", "approve mapping")
  assert_equal(vim.fn.maparg("A", "n", false, true).desc, "Approve all LazyAgent ACP changes", "approve all mapping")
  assert_equal(vim.fn.maparg("<CR>", "n", false, true).desc, "Open LazyAgent ACP changed file", "open file mapping")
  assert_equal(vim.fn.maparg("d", "n", false, true).desc, "Open LazyAgent ACP diff tab", "diff tab mapping")
  assert_equal(vim.fn.maparg("k", "n", false, true).buffer or 0, 0, "k remains normal movement")

  vim.api.nvim_feedkeys("]t", "x", false)
  vim.wait(100)
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
  vim.cmd("wincmd h")
  assert_equal(vim.wo.diff, true, "before side has diff mode enabled")
  assert_equal(vim.fn.maparg("q", "n", false, true).desc, "Close LazyAgent ACP diff tab", "before diff close mapping")
  vim.api.nvim_feedkeys("q", "x", false)
  vim.wait(100)
  assert_equal(vim.fn.tabpagenr("$"), tabs_before, "q closes the whole diff tab")
  assert_equal(vim.api.nvim_get_current_buf(), drawer, "q returns to the changes drawer")
  live_thread = vim.deepcopy(thread)
  live_thread.change_journal.turns[#live_thread.change_journal.turns + 1] = {
    turn_id = "thread-1:3", state = "active",
    changes = { { operation = "added", path = "lua/live.lua", after_blob = "after-a" } },
  }
  vim.api.nvim_exec_autocmds("User", {
    pattern = "LazyAgentChangeJournal", data = { thread_id = "thread-1", turn_id = "thread-1:3", state = "active" },
  })
  vim.wait(100)
  assert(vim.api.nvim_buf_get_lines(drawer, 1, 2, false)[1]:find("live", 1, true),
    "open Changes drawer follows active turn updates")
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
