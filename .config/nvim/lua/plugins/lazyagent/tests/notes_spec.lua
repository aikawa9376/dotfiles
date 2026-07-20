local M = {}

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

local function contains(haystack, needle, message)
  if not tostring(haystack):find(needle, 1, true) then
    error(string.format("%s: %q does not contain %q", message, haystack, needle))
  end
end

local function title_text(winid)
  local title = vim.api.nvim_win_get_config(winid).title
  if type(title) == "string" then return title end
  local parts = {}
  for _, chunk in ipairs(type(title) == "table" and title or {}) do
    parts[#parts + 1] = type(chunk) == "table" and tostring(chunk[1] or "") or tostring(chunk)
  end
  return table.concat(parts)
end

function M.run()
  local notes = require("lazyagent.notes")
  local transforms = require("lazyagent.transforms")
  local previous_cwd = vim.fn.getcwd()
  local dir = vim.fn.tempname() .. "-lazyagent-notes"
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/sample.lua"
  vim.fn.writefile({ "local a = 1", "local b = 2", "return a + b" }, path)
  vim.cmd("cd " .. vim.fn.fnameescape(dir))
  local bufnr = vim.fn.bufadd(path)
  vim.fn.bufload(bufnr)

  notes._reset()
  local first = assert(notes.add({ bufnr = bufnr, start_line = 2, end_line = 3, text = "Is this range correct?" }))
  assert_equal(notes.count({ source_bufnr = bufnr }), 1, "Note count")
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, notes.namespace, 0, -1, { details = true })
  assert_equal(#marks, 3, "range Note uses separate anchor, background, and icon extmarks")
  local icon_mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, notes.namespace, first.icon_mark_id, { details = true })
  assert_equal(icon_mark[1], 1, "Note icon starts on the selected line")
  assert_equal(icon_mark[3].virt_text_pos, "eol", "Note icon defaults to end-of-line")
  assert_equal(icon_mark[3].sign_text, nil, "end-of-line mode does not occupy the gutter")
  local background = vim.api.nvim_buf_get_extmark_by_id(
    bufnr,
    notes.namespace,
    first.background_mark_id,
    { details = true }
  )
  assert_equal(background[3].hl_group, "LazyAgentNoteRange", "multiline Note has a subtle range background")
  assert_equal(background[3].end_row, 3, "range background covers all selected lines")

  vim.api.nvim_buf_set_lines(bufnr, 3, 3, false, { "-- inserted below Note" })
  local unchanged = notes.render({ source_bufnr = bufnr })
  contains(unchanged, "@sample.lua:2-3", "insertion below a Note does not extend its range")
  icon_mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, notes.namespace, first.icon_mark_id, { details = true })
  assert_equal(icon_mark[1], 1, "insertion below does not move the Note icon")

  vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "-- inserted" })
  local rendered, ids = notes.render({ source_bufnr = bufnr })
  contains(rendered, "@sample.lua:3-4 Is this range correct?", "extmark range follows edits")
  icon_mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, notes.namespace, first.icon_mark_id, { details = true })
  assert_equal(icon_mark[1], 2, "Note icon follows its anchor without moving to the following line")
  assert_equal(ids[1], first.id, "rendered Note id")

  local preview, preview_meta = transforms.preview_token("notes", { source_bufnr = bufnr })
  contains(preview, "@sample.lua:3-4", "Notes preview")
  assert_equal(notes.count({ source_bufnr = bufnr }), 1, "preview does not consume Notes")
  assert_equal(preview_meta.note_ids[1], first.id, "preview Note metadata")

  local expanded, meta = transforms.expand("Please handle #notes", { source_bufnr = bufnr })
  contains(expanded, "Please handle Address the following saved code Notes", "Notes expansion")
  assert_equal(meta.note_ids[1], first.id, "expanded Note metadata")
  assert_equal(notes.consume_meta(meta), 1, "consume sent Notes")
  assert_equal(notes.count({ source_bufnr = bufnr }), 0, "Notes cleared after consume")
  assert_equal(#vim.api.nvim_buf_get_extmarks(bufnr, notes.namespace, 0, -1, {}), 0, "consumed extmark removed")

  local state = require("lazyagent.logic.state")
  local previous_notes = state.opts.notes
  state.opts.notes = { icon_position = "gutter" }
  local gutter_note = assert(notes.add({ bufnr = bufnr, start_line = 2, end_line = 2, text = "Gutter mode" }))
  local gutter_icon = vim.api.nvim_buf_get_extmark_by_id(
    bufnr,
    notes.namespace,
    gutter_note.icon_mark_id,
    { details = true }
  )
  assert_equal(vim.trim(gutter_icon[3].sign_text), "󰆉", "gutter icon remains available through opts")
  assert_equal(gutter_icon[3].virt_text, nil, "gutter mode does not add end-of-line virtual text")
  local gutter_background = vim.api.nvim_buf_get_extmark_by_id(
    bufnr,
    notes.namespace,
    gutter_note.background_mark_id,
    { details = true }
  )
  assert_equal(gutter_background[3].hl_group, "LazyAgentNoteRange", "single-line Note also has a range background")
  assert_equal(gutter_background[3].end_row, 2, "single-line background covers only its target line")
  assert_equal(notes.remove(gutter_note.id), true, "gutter Note removed")
  state.opts.notes = previous_notes

  local window = require("lazyagent.window")
  local source_winid = vim.api.nvim_get_current_win()
  local shared_buf = window.create_scratch_buffer({
    filetype = "markdown",
    source_bufnr = bufnr,
    source_winid = source_winid,
  })
  local shared_win = window.open(shared_buf, {
    window_type = "float",
    source_winid = source_winid,
    title = " Old scratch title ",
  })
  local editor_buf, editor_win = notes.open_editor({
    bufnr = bufnr,
    start_line = 1,
    end_line = 2,
    source_winid = source_winid,
    window_type = "float",
  })
  assert_equal(vim.b[editor_buf].lazyagent_note_editor, true, "long-form Note editor marker")
  assert_equal(vim.b[editor_buf].lazyagent_is_scratch, true, "Note editor uses LazyAgent scratch buffer defaults")
  assert_equal(vim.api.nvim_win_is_valid(editor_win), true, "long-form Note editor window")
  assert_equal(editor_win, shared_win, "Note editor reuses the shared scratch window")
  assert_equal(title_text(editor_win), " LazyAgent Note ", "Note editor uses the shared scratch title")
  vim.api.nvim_buf_set_lines(editor_buf, 0, -1, false, { "Explain why this works.", "Then simplify the implementation." })
  local long_note = assert(notes.submit_editor(editor_buf))
  pcall(vim.api.nvim_buf_delete, shared_buf, { force = true })
  assert_equal(long_note.text, "Explain why this works.\nThen simplify the implementation.", "multiline Note text")
  assert_equal(notes.count({ source_bufnr = bufnr }), 1, "long-form editor saves Note")
  local long_rendered = notes.render({ source_bufnr = bufnr })
  contains(long_rendered, "Explain why this works.\n  Then simplify the implementation.", "multiline Note expansion")
  assert_equal(notes.show_at_cursor({ bufnr = bufnr, lnum = 1 }), true, "focused Note preview")
  local preview_win = vim.api.nvim_get_current_win()
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = vim.api.nvim_get_current_buf() })
  assert_equal(vim.api.nvim_win_is_valid(preview_win), true, "focused preview remains scrollable")
  notes._reset()

  local available = transforms.available_tokens({ source_bufnr = bufnr })
  for _, token in ipairs(available) do
    if token.name == "notes" then error("#notes should be hidden when the workspace has no Notes") end
  end

  notes._reset()
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  vim.cmd("cd " .. vim.fn.fnameescape(previous_cwd))
  vim.fn.delete(dir, "rf")
end

return M
