local M = {}
function M.run()
  local notes = require('lazyagent.notes')
  local source = require('lazyagent.note_source')
  local old = package.loaded['git.features.status_renderer']
  local repo = vim.fn.tempname()
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(b, 'git-status://' .. repo)
  vim.bo[b].filetype = 'fugitivestatus'
  vim.b[b].fugitive_work_tree = repo
  vim.b[b].git_dir = repo .. '/.git'
  local entry = { section = 'unstaged', path = 'a file.lua' }
  local staged = { section = 'staged', path = 'a file.lua' }
  local model = {}
  package.loaded['git.features.status_renderer'] = {
    entry_at = function(buf, row) return buf == b and model[row] end,
    entry_row = function(_, row)
      local target = model[row]
      for i = 1, row do if model[i] == target then return i end end
    end,
  }
  local function render(expanded, shifted)
    local lines = shifted and { 'Head: new', '' } or {}
    local row = #lines + 1
    vim.list_extend(lines, { 'M a file.lua' })
    if expanded then vim.list_extend(lines, { '@@ -1 +1 @@', '-old', '+new' }) end
    lines[#lines + 1] = ''
    lines[#lines + 1] = 'M a file.lua'
    model = {}
    for i = row, #lines - 2 do model[i] = entry end
    model[#lines] = staged
    vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
    notes.refresh_buffer(b)
    return row
  end
  notes._reset()
  render(true)
  local note = assert(notes.add({ bufnr = b, root = repo, start_line = 3, end_line = 4, text = 'Review both sides' }))
  assert(note.source.status and note.source.path == 'a file.lua' and note.source.section == 'unstaged')
  local prompt = notes.render({ root = repo })
  assert(prompt:find('@a file.lua', 1, true))
  assert(not prompt:find('status --short', 1, true) and prompt:find('> -old', 1, true) and prompt:find('> +new', 1, true))
  assert(not prompt:find('a file.lua:3', 1, true), 'status coordinates must not be claimed as file lines')
  local selection = source.selection_text(b, 3, 4)
  assert(selection:find('@a file.lua', 1, true))
  assert(source.selection_text(b, 4, 4):find('@a file.lua:1', 1, true), 'added row maps to worktree line')
  assert(not source.selection_text(b, 3, 3):find('@a file.lua:', 1, true), 'deleted rows must not claim a current line')
  assert(source.selection_text(b, 1, 1) == '@a file.lua', 'file header should be a plain path')
  local function icon_row()
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(b, notes.namespace, 0, -1, { details = true })) do
      if mark[3] == 0 and mark[4].virt_text then return mark[2] + 1 end
    end
  end
  assert(icon_row() == 3)
  render(false)
  assert(icon_row() == 1, 'collapsed Note should follow its file, not the next section')
  render(true, true)
  assert(icon_row() == 5, 'expansion should restore the selected hunk after preceding rows change')
  local snapshot = notes.snapshot()
  notes.restore(snapshot)
  assert(icon_row() == 5, 'session restore must preserve semantic status identity')
  render(false, true)
  local window = vim.api.nvim_get_current_win()
  local previous = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_current_buf(b)
  local old_status = package.loaded['git.features.status']
  package.loaded['git.features.status'] = { open = function() return b end }
  package.loaded['git.features.status_renderer'].update_diff = function() render(true, true) end
  assert(notes.jump(snapshot.entries[1].id or 1))
  assert(vim.api.nvim_win_get_cursor(window)[1] == 5, 'jump should reopen the selected diff')
  package.loaded['git.features.status'] = old_status
  vim.api.nvim_set_current_buf(previous)
  model = {}
  notes.refresh_buffer(b)
  assert(icon_row() == nil, 'removed status entry must not leave a misplaced icon')
  notes._reset()
  vim.api.nvim_buf_delete(b, { force = true })
  package.loaded['git.features.status_renderer'] = old
end
return M
