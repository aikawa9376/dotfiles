local M = {}
function M.run()
  local initial_win = vim.api.nvim_get_current_win()
  local initial_windows, initial_buffers = {}, {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do initial_windows[win] = true end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do initial_buffers[buf] = true end
  local notes = require("lazyagent.notes")
  local transforms = require("lazyagent.transforms")
  local root = vim.fn.tempname() .. "-review-notes"
  vim.fn.mkdir(root, "p")
  local function git(...)
    local cmd = { "git", "-C", root }
    vim.list_extend(cmd, { ... })
    local r = vim.system(cmd, { text = true }):wait()
    assert(r.code == 0, r.stderr)
    return vim.trim(r.stdout)
  end
  git("init", "-q")
  vim.fn.writefile({ "old first", "old second" }, root .. "/a file.lua")
  git("add", ".")
  git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "initial")
  local commit = git("rev-parse", "HEAD")
  vim.fn.writefile({ "current content" }, root .. "/a file.lua")
  local function buffer(name, lines)
    local b = vim.api.nvim_create_buf(false, true)
    if name then vim.api.nvim_buf_set_name(b, name) end
    vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
    return b
  end
  notes._reset()
  -- Ordinary files retain the last tracked range across wipe/reload.
  local plain = vim.fn.bufadd(root .. "/a file.lua")
  vim.fn.bufload(plain)
  notes.add({ bufnr = plain, root = root, text = "ordinary reopen", icon = "!" })
  vim.api.nvim_buf_set_lines(plain, 0, 0, false, { "inserted" })
  vim.fn.writefile(vim.api.nvim_buf_get_lines(plain, 0, -1, false), root .. "/a file.lua")
  vim.api.nvim_buf_delete(plain, { force = true })
  plain = vim.fn.bufadd(root .. "/a file.lua")
  vim.fn.bufload(plain)
  assert(vim.wait(1000, function() return #vim.api.nvim_buf_get_extmarks(plain, notes.namespace, 0, -1, {}) == 3 end, 10), "ordinary marks restored on read")
  assert(notes.show_at_cursor({ bufnr = plain, lnum = 2, focus = false, silent = true }), "ordinary Note follows saved position after reopen")
  notes._reset()
  assert(not pcall(vim.api.nvim_get_autocmds, { group = "LazyAgentNotesLifecycle" }), "no restore handlers without Notes")
  vim.api.nvim_buf_delete(plain, { force = true })
  vim.fn.writefile({ "current content" }, root .. "/a file.lua")
  local a = buffer(nil, { "unnamed first" })
  local b = buffer(nil, { "unnamed second" })
  local first = assert(notes.add({ bufnr = a, root = root, text = "fix first" }))
  assert(notes.show_at_cursor({ bufnr = b, lnum = 1, silent = true }) == false, "unnamed buffers must not share Notes")
  local text = notes.render({ root = root })
  assert(text:find("unnamed first", 1, true), "anonymous excerpt included")
  assert(not text:find("Git references", 1, true), "no Git preamble for anonymous Notes")
  vim.api.nvim_buf_delete(a, { force = true })
  assert(notes.jump(first.id), "deleted anonymous buffer falls back to preview")
  notes._reset()

  local historical = buffer("diffview://" .. root .. "/.git/" .. commit:sub(1,11) .. "/a file.lua", { "old first", "old second" })
  local old_lib = package.loaded["diffview.lib"]
  package.loaded["diffview.lib"] = { views = {{ cur_layout = {
    symbols = { "a" }, get_file_for = function()
      return { bufnr = historical, adapter = { ctx = { toplevel = root } }, path = "a file.lua", rev = { commit = commit } }
    end,
  }}} }
  local review = assert(notes.add({ bufnr = historical, start_line = 2, text = "fix this in current code" }))
  assert(review.source.side == "a" and review.root == root, "Diffview metadata owns side and workspace")
  local normal = vim.fn.bufadd(root .. "/a file.lua")
  vim.fn.bufload(normal)
  local expanded, meta = transforms.expand("#notes", { source_bufnr = normal })
  assert(expanded:find(commit, 1, true), "full revision sent from working-tree scratch")
  assert(expanded:find(root .. "/.git//" .. commit .. "/a file.lua:2", 1, true), "compact commit reference includes saved file row")
  local _, instructions = expanded:gsub("Git references", "")
  assert(instructions == 1, "Git reading instruction appears once")
  assert(not expanded:find("old second", 1, true), "Git reference does not send selected code")
  assert(not expanded:find("Selected code", 1, true), "Git reference omits excerpt heading")
  assert(meta.note_ids[1] == review.id)
  vim.cmd("split")
  vim.api.nvim_win_set_buf(0, historical)
  local win = vim.api.nvim_get_current_win()
  assert(notes.jump(review.id) and vim.api.nvim_get_current_win() == win, "jump returns to original pane")
  vim.api.nvim_buf_delete(historical, { force = true })
  local upper = vim.api.nvim_get_current_win()
  local list = notes.open({ root = root })
  local list_win = vim.api.nvim_get_current_win()
  local win_count = #vim.api.nvim_list_wins()
  assert(notes.jump(review.id), "closed historical buffer restores blob")
  assert(vim.api.nvim_get_current_line() == "old second", "restore opens historical line, not worktree")
  assert(vim.bo.modifiable == false, "restored revision is read-only")
  assert(vim.api.nvim_get_current_win() == upper, "restored blob uses upper window")
  assert(vim.api.nvim_win_get_buf(list_win) == list, "Notes list remains open")
  assert(#vim.api.nvim_list_wins() == win_count, "restoration does not add a bottom split")
  vim.api.nvim_win_close(list_win, true)
  package.loaded["diffview.lib"] = old_lib
  local reopened = buffer("diffview://" .. root .. "/.git/" .. commit .. "/a file.lua", { "old first", "old second" })
  vim.api.nvim_exec_autocmds("BufWinEnter", { buffer = reopened })
  assert(vim.wait(1000, function() return #vim.api.nvim_buf_get_extmarks(reopened, notes.namespace, 0, -1, {}) == 3 end, 10), "review marks restored by immutable identity")
  assert(notes.show_at_cursor({ bufnr = reopened, lnum = 2, focus = false, silent = true }), "review hover restored")
  vim.api.nvim_exec_autocmds("BufWinEnter", { buffer = reopened })
  vim.wait(20)
  assert(#vim.api.nvim_buf_get_extmarks(reopened, notes.namespace, 0, -1, {}) == 3, "repeated events do not duplicate marks")
  notes._reset()
  assert(#vim.api.nvim_buf_get_extmarks(reopened, notes.namespace, 0, -1, {}) == 0, "consumption clears reattached marks")
  vim.api.nvim_buf_delete(reopened, { force = true })

  -- URI fallback works without Diffview loaded, including an index snapshot
  -- whose contents must survive a later index update.
  git("add", ".")
  local staged = buffer("diffview://" .. root .. "/.git/:0:/a file.lua", { "current content" })
  local index_note = assert(notes.add({ bufnr = staged, text = "index comment" }))
  assert(index_note.source.revision == ":0")
  vim.fn.writefile({ "newer index" }, root .. "/a file.lua")
  git("add", ".")
  local index_text = notes.render({ root = root })
  assert(index_text:find(root .. "/.git//blob/" .. index_note.source.blob .. "/a file.lua:1", 1, true), "render keeps captured index blob")
  assert(index_note.source.blob ~= git("rev-parse", ":0:a file.lua"), "saved blob differs from updated index")
  assert(not index_text:find("current content", 1, true), "index reference omits excerpt")
  vim.api.nvim_buf_delete(staged, { force = true })
  assert(notes.jump(index_note.id))
  assert(vim.api.nvim_get_current_line() == "current content", "index reopening uses captured blob")
  notes._reset()
  -- The canonical patch contains a second file with identical added text.
  vim.fn.writefile({ "newer index" }, root .. "/b file.lua")
  git("add", "b file.lua")
  -- Commit review rows refer to one fixed show output, across either side.
  git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "change")
  local changed_commit = git("rev-parse", "HEAD")
  local patch = vim.split(git("show", "--format=medium", "--no-color", "HEAD", "--", "a file.lua"), "\n", { plain = true })
  local diff = buffer(root .. "/commit.patch", patch)
  vim.bo[diff].filetype = "git"
  local removed, added
  for i, row in ipairs(patch) do
    if row == "-old second" then removed = i end
    if row == "+newer index" then added = i end
  end
  assert(removed and added)
  local old_note = assert(notes.add({ bufnr = diff, root = root, start_line = removed, text = "old side" }))
  local new_note = assert(notes.add({ bufnr = diff, root = root, start_line = added, text = "new side" }))
  local mixed = assert(notes.add({ bufnr = diff, root = root, start_line = removed, end_line = added, text = "both sides" }))
  local rendered = notes.render({ root = root })
  local canonical = require("lazyagent.note_show").read(root, changed_commit)
  local old_row, new_row
  for i, row in ipairs(canonical) do
    if row == "-old second" then old_row = i end
    if row == "+newer index" and not new_row then new_row = i end
  end
  local prefix = root .. "/.git//show/" .. changed_commit .. ":"
  assert(rendered:find(prefix .. old_row .. " old side", 1, true), "deleted row references commit patch")
  assert(rendered:find(prefix .. new_row .. " new side", 1, true), "added row references same commit patch")
  assert(rendered:find(prefix .. old_row .. "-" .. new_row .. " both sides", 1, true), "mixed-side range is one show reference")
  assert(mixed.source.show and not rendered:find("Selected code", 1, true), "commit ranges do not send excerpts")
  assert(old_note.source.start_line == old_row and new_note.source.start_line == new_row)
  local _, preambles = rendered:gsub("//show/<commit>:", "")
  assert(preambles == 1, "show command included once for multiple Notes")
  assert(not rendered:find("cat-file", 1, true), "unused reference instructions omitted")
  local launched
  local actions = require("lazyagent.logic.session.actions").setup({
    state = { sessions = {} }, window = { is_open = function() return false end },
    agent_logic = { get_interactive_agent = function() return {} end,
      resolve_target_agent = function(name, _, callback) callback(name) end },
    backend_logic = { resolve_backend_for_agent = function() return "test" end },
    acp_logic = { is_acp_backend = function() return false end },
    start_interactive_session = function(opts) launched = opts end,
  })
  vim.api.nvim_win_set_buf(0, diff)
  vim.api.nvim_win_set_cursor(0, { added, 0 })
  vim.cmd("normal! V")
  vim.api.nvim_win_set_cursor(0, { removed, 0 })
  actions.toggle_session("Test")
  vim.cmd("normal! " .. vim.api.nvim_replace_termcodes("<Esc>", true, false, true))
  assert(launched.initial_input:find(prefix .. old_row .. "-" .. new_row, 1, true), "visual scratch uses same show range, including reversed selection")
  assert(not launched.initial_input:find("Selected code", 1, true), "visual scratch sends a reference rather than a patch excerpt")
  assert(notes.count({ root = root }) == 3, "opening scratch does not create or consume Notes")
  vim.api.nvim_buf_delete(diff, { force = true })
  assert(notes.jump(mixed.id))
  assert(vim.api.nvim_get_current_line() == "-old second", "fallback restores canonical patch rather than a file side")
  assert(notes.show_at_cursor({ lnum = old_row, focus = false, silent = true }), "mixed Note preview on restored patch")
  local reopened_patch = buffer(nil, patch)
  vim.bo[reopened_patch].filetype = "git"
  vim.api.nvim_exec_autocmds("BufWinEnter", { buffer = reopened_patch })
  assert(vim.wait(1000, function() return #vim.api.nvim_buf_get_extmarks(reopened_patch, notes.namespace, 0, -1, {}) == 9 end, 10), "all commit Notes reattach to display rows")
  assert(notes.show_at_cursor({ bufnr = reopened_patch, lnum = added, focus = false, silent = true }), "mixed-side Note hover restored")
  notes._reset()
  local full_patch = vim.split(git("show", "--format=medium", "--no-color", "HEAD"), "\n", { plain = true })
  local multi = buffer(root .. "/multi.patch", full_patch)
  vim.bo[multi].filetype = "git"
  local first_patch_row, last_patch_row
  for i, row in ipairs(full_patch) do
    if row == "-old second" then first_patch_row = i end
    if row == "+newer index" then last_patch_row = i end
  end
  local multi_note = assert(notes.add({ bufnr = multi, root = root, start_line = first_patch_row, end_line = last_patch_row, text = "multiple files" }))
  assert(multi_note.source.show and multi_note.source.start_line == old_row and multi_note.source.end_line == #canonical,
    "selection across files maps without confusing identical added lines")
  notes._reset()
  -- Fugitive's public Parse and WorkTree contracts; plugin need not be installed.
  vim.cmd([[function! FugitiveWorkTree(dir) abort
    return g:note_test_root
  endfunction]])
  local autoload = root .. "/autoload"
  vim.fn.mkdir(autoload, "p")
  vim.fn.writefile({ 'function! fugitive#Parse(url) abort', 'return [g:note_test_commit . ":a file.lua", g:note_test_root . "/.git"]', 'endfunction' }, autoload .. "/fugitive.vim")
  vim.cmd("source " .. vim.fn.fnameescape(autoload .. "/fugitive.vim"))
  vim.g.note_test_root, vim.g.note_test_commit = root, commit
  local fugitive = buffer("fugitive://" .. root .. "/.git//" .. commit .. "/a file.lua", { "old first", "old second" })
  local f = assert(notes.add({ bufnr = fugitive, text = "fugitive review" }))
  assert(f.source.kind == "fugitive" and f.source.revision == commit and f.root == root)
  notes._reset()
  vim.api.nvim_buf_delete(fugitive, { force = true })
  vim.api.nvim_buf_delete(b, { force = true })
  vim.cmd("delfunction FugitiveWorkTree")
  vim.cmd("delfunction fugitive#Parse")
  vim.g.note_test_root, vim.g.note_test_commit = nil, nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if not initial_windows[win] then pcall(vim.api.nvim_win_close, win, true) end
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if not initial_buffers[buf] then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
  end
  if vim.api.nvim_win_is_valid(initial_win) then vim.api.nvim_set_current_win(initial_win) end
  vim.fn.delete(root, "rf")
end
return M
