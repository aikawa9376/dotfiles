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
  assert_equal(#vim.api.nvim_buf_get_extmarks(bufnr, notes.namespace, 0, -1, {}), 1, "Note extmark")

  vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "-- inserted" })
  local rendered, ids = notes.render({ source_bufnr = bufnr })
  contains(rendered, "@sample.lua:3-4 Is this range correct?", "extmark range follows edits")
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
