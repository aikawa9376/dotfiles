-- Independent commit view.
local M = {}
local utils = require('git.utils')
local objects = require('git.objects')
local actions = require('git.features.commit_actions')
local model_api = require('git.features.commit_model')
local display = require('git.features.change_display')
local rewrite = require('git.features.commit_rewrite')
local syntax = require('git.features.syntax_highlight')
local states = {}
-- Deleted buffers leave only view metadata behind, never full patches/models.
local saved_views = {}
local function remember_view(s)
  local saved = saved_views[s.buf] or { windows = {} }
  saved.expanded, saved.parent = vim.deepcopy(s.expanded), s.model.parent_index
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) == s.buf then
    saved.view = vim.fn.winsaveview()
    saved.windows[win] = saved.view
  end
  saved_views[s.buf] = saved
end
local function restore_view(s)
  local saved = saved_views[s.buf]
  if not saved or vim.api.nvim_get_current_buf() ~= s.buf then return end
  local view = saved.windows[vim.api.nvim_get_current_win()] or saved.view
  if view then vim.fn.winrestview(vim.deepcopy(view)) end
end
local function ordinary_window()
  for _, name in ipairs({ 'number', 'relativenumber', 'wrap', 'foldmethod', 'foldenable', 'foldcolumn' }) do
    vim.api.nvim_set_option_value(name, vim.api.nvim_get_option_value(name, { scope = 'global' }), { win = 0, scope = 'local' })
  end
end
local ns = vim.api.nvim_create_namespace('fugitive_commit_view')
local status_highlights = {
  A = 'GitSignsAdd',
  M = 'Structure',
  D = 'GitSignsDelete',
  R = 'Structure',
  C = 'Structure',
  T = 'Structure',
  U = 'Structure',
}
local serial = 0
local function buffer_name(root, hash, id)
  return ('git-commit://%s/%d/%s'):format(root, id, hash)
end
local function close_flog()
  local win = vim.g.flog_win
  vim.g.flog_win, vim.g.flog_bufnr, vim.g.flog_opener_bufnr = nil, nil, nil
  if win and vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, false) end
end
local function close_inspection()
  close_flog()
  local commands = require('git.features.commands')
  if commands.close_commit_info_float then commands.close_commit_info_float() end
  local return_win = vim.w.fugitive_commit_return_win
  local regular_windows = 0
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local config = vim.api.nvim_win_get_config(win)
    if config.relative == '' and not config.external then regular_windows = regular_windows + 1 end
  end
  if regular_windows > 1 then
    vim.api.nvim_win_close(0, false)
  elseif #vim.api.nvim_list_tabpages() > 1 then
    vim.cmd('tabclose')
  else
    require('utilities').smart_close()
  end
  if return_win and vim.api.nvim_win_is_valid(return_win) then vim.api.nvim_set_current_win(return_win) end
end
local function show_buffer(buf)
  local previous = vim.api.nvim_get_current_buf()
  if previous ~= buf and vim.g.flog_opener_bufnr == previous then
    vim.g.flog_opener_bufnr = buf
  end
  vim.api.nvim_win_set_buf(0, buf)
end
local function notify(err) vim.notify(tostring(err), vim.log.levels.ERROR) end
local function state(buf) return states[buf == 0 and vim.api.nvim_get_current_buf() or buf] end
function M.model(buf) local s = state(buf); return s and s.model end

local function message(s)
  local lines = vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)
  if #lines < #s.prefix + #s.suffix + 1 then return nil, 'Only the commit message may be edited' end
  for i, text in ipairs(s.prefix) do
    if lines[i] ~= text then return nil, 'Commit metadata is read-only; undo that edit before saving' end
  end
  local tail = #lines - #s.suffix
  for i, text in ipairs(s.suffix) do
    if lines[tail + i] ~= text then return nil, 'Diffs are read-only; undo that edit before saving' end
  end
  return vim.list_slice(lines, #s.prefix + 1, tail)
end
local function message_dirty(s)
  local current = message(s)
  return not current or not vim.deep_equal(current, s.model.message)
end
local function editable_row(s, row)
  return row > #s.prefix and row <= vim.api.nvim_buf_line_count(s.buf) - #s.suffix
end
function M.entry_at(buf, row)
  local s = state(buf)
  if not s then return nil end
  -- Message edits can shift every file row before the next render.
  local delta = vim.api.nvim_buf_line_count(s.buf) - s.line_count
  if editable_row(s, row) or row <= #s.prefix then return nil end
  local info = s.rows[row - delta]
  return info and info.entry, info
end
local function in_message(s) return editable_row(s, vim.api.nvim_win_get_cursor(0)[1]) end
local function render(s, edited)
  local model = s.model
  local prefix = vim.deepcopy(model.header)
  local msg = edited or model.message
  if #msg == 0 then msg = { '' } end
  local lines = vim.list_extend(vim.deepcopy(prefix), msg)
  local suffix_start = #lines + 1
  vim.list_extend(lines, { '', ('Changes (%d)'):format(#model.entries) })
  local rows = {}
  for _, entry in ipairs(model.entries) do
    lines[#lines + 1] = display.line(entry)
    rows[#lines] = { entry = entry, header = true }
    if s.expanded[entry.path] then
      local diff, start = model_api.inline(model, entry)
      if not diff then notify(start); diff = {} end
      for i, line in ipairs(diff) do
        lines[#lines + 1] = line
        rows[#lines] = { entry = entry, patch_row = start and start + i - 1 }
      end
    end
  end
  s.prefix, s.suffix = prefix, vim.list_slice(lines, suffix_start)
  s.rows, s.line_count = rows, #lines
  vim.bo[s.buf].modifiable = true
  vim.bo[s.buf].readonly = false
  vim.api.nvim_buf_set_lines(s.buf, 0, -1, false, lines)
  vim.bo[s.buf].modified = not vim.deep_equal(msg, model.message)
  vim.bo[s.buf].bufhidden = vim.bo[s.buf].modified and 'hide' or 'delete'
  vim.api.nvim_buf_clear_namespace(s.buf, ns, 0, -1)
  vim.api.nvim_buf_set_extmark(s.buf, ns, suffix_start, 0, { end_col = #lines[suffix_start + 1], hl_group = 'Title' })
  for row, info in pairs(rows) do
    if info.header then
      local entry = info.entry
      local status_hl = status_highlights[entry.status]
      if status_hl then
        vim.api.nvim_buf_set_extmark(s.buf, ns, row - 1, 0, { end_col = 1, hl_group = status_hl })
      end
      local chunks = display.statistics(entry)
      if #chunks > 0 then vim.api.nvim_buf_set_extmark(s.buf, ns, row - 1, 0, { virt_text = chunks, virt_text_pos = 'eol' }) end
      local icon, hl = utils.get_devicon(entry.path)
      vim.api.nvim_buf_set_extmark(s.buf, ns, row - 1, 2, { end_col = #lines[row], hl_group = hl,
        virt_text = { { icon .. ' ', hl } }, virt_text_pos = 'inline' })
    end
  end
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = s.buf })
  local notes = package.loaded['lazyagent.notes']
  if notes then notes.refresh_buffer(s.buf) end
end
local function render_preserving_message(s)
  local current, err = message(s)
  if not current then notify(err); return false end
  render(s, current)
  return true
end
local function configure_window()
  for name, value in pairs({ foldmethod = 'manual', foldenable = false, foldcolumn = '0',
    wrap = false, number = false, relativenumber = false }) do
    vim.api.nvim_set_option_value(name, value, { win = 0, scope = 'local' })
  end
end
local function focus_path(s, path)
  for row, info in pairs(s.rows) do
    if info.header and info.entry.path == path then
      local delta = vim.api.nvim_buf_line_count(s.buf) - s.line_count
      vim.api.nvim_win_set_cursor(0, { row + delta, 0 }); return
    end
  end
end
local function replace_model(s, hash)
  local model, err = model_api.load(s.model.root, hash, s.model.parent_index)
  if not model then notify(err); return false end
  s.model = model
  s.expected_head = vim.trim(model_api.git(model.root, { 'rev-parse', 'HEAD' }) or '')
  vim.b[s.buf].fugitive_commit = model.hash
  vim.api.nvim_buf_set_name(s.buf, buffer_name(model.root, model.hash, s.view_id))
  render(s)
  return true
end
function M.expand_file(buf, path)
  local s = state(buf)
  if not s then return false end
  s.expanded[path] = true
  return render_preserving_message(s)
end
function M.write(buf)
  local s = state(buf)
  if not s or s.writing then return false end
  local current, err = message(s)
  if not current then notify(err); return false end
  if vim.deep_equal(current, s.model.message) then vim.bo[s.buf].modified = false; return true end
  s.writing = true
  local ok, hash, warning = pcall(rewrite.apply, s.model.root, s.model.hash, { message = current, expected_head = s.expected_head })
  s.writing = false
  if not ok or not hash then notify(ok and warning or hash); return false end
  replace_model(s, hash)
  if warning then vim.notify(warning, vim.log.levels.WARN) end
  return true
end
local function clean_action(s)
  if message_dirty(s) then notify('Save or undo message edits before this action'); return false end
  return true
end
local function toggle(s, mode, first, last)
  local current, err = message(s)
  if not current then notify(err); return end
  local selected = {}
  for row = first or vim.fn.line('.'), last or vim.fn.line('.') do
    local entry = M.entry_at(s.buf, row)
    if entry then selected[entry.path] = true end
  end
  if next(selected) == nil then
    for _, entry in ipairs(s.model.entries) do selected[entry.path] = true end
  end
  local cursor_entry = M.entry_at(s.buf, vim.fn.line('.'))
  for path in pairs(selected) do s.expanded[path] = mode == 'show' or (mode == 'toggle' and not s.expanded[path]) end
  render(s, current)
  if cursor_entry then focus_path(s, cursor_entry.path) end
end
local function move(s, direction, hunks, expand)
  if not render_preserving_message(s) then return end
  for _ = 1, vim.v.count1 do
    local entry = M.entry_at(s.buf, vim.fn.line('.'))
    if hunks and entry and not s.expanded[entry.path] then toggle(s, 'show') end
    local row = vim.fn.line('.')
    local lines = vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)
    for candidate = row + direction, direction == 1 and #lines or 1, direction do
      local info = s.rows[candidate]
      if info and (info.header or (hunks and lines[candidate]:match('^@@'))) then
        if not hunks and entry then s.expanded[entry.path] = false end
        vim.api.nvim_win_set_cursor(0, { candidate, 0 })
        if expand or (hunks and info.header) then
          toggle(s, 'show')
          if hunks then
            local next_row = vim.fn.line('.') + 1
            if (vim.api.nvim_buf_get_lines(s.buf, next_row - 1, next_row, false)[1] or ''):match('^@@') then
              vim.api.nvim_win_set_cursor(0, { next_row, 0 })
            end
          end
        elseif not hunks then
          toggle(s, 'hide')
        end
        break
      end
    end
  end
end
local function target_line(s, info, before)
  if not info or not info.patch_row then return 1 end
  local patch = model_api.patch(s.model, info.entry)
  local n
  for i = info.patch_row, 1, -1 do
    n = tonumber(patch[i]:match(before and '^@@ %-(%d+)' or '^@@ %-%d+,?%d* %+(%d+)'))
    if n then
      for j = i + 1, info.patch_row - 1 do
        if patch[j]:match(before and '^[ %-]' or '^[ +]') then n = n + 1 end
      end
      return math.max(1, n)
    end
  end
  return 1
end
local function blob(s, entry, before)
  local rev = before and s.model.base or s.model.hash
  local path = before and (entry.old_path or entry.path) or entry.path
  if (before and entry.status == 'A') or (not before and entry.status == 'D') then return {} end
  local content, err = model_api.git(s.model.root, { 'show', rev .. ':' .. path })
  if not content then return nil, err end
  return model_api.lines(content)
end
local function show_blob(s, entry, before)
  local rev = before and s.model.base or s.model.hash
  local path = before and (entry.old_path or entry.path) or entry.path
  local content, err = blob(s, entry, before)
  if not content then notify(err); return end
  -- The repository and immutable object identify a preview; no open counter
  -- belongs in its filename. Reuse one already visible in another window.
  local name = objects.uri(s.model.root, rev .. ':' .. path):gsub('^git%-object:', 'git-commit-blob:')
  local b = vim.fn.bufnr(name)
  -- Merge-parent selections may show one blob against different bases.
  if b ~= -1 and vim.b[b].git_blob_base ~= s.model.base then
    name = name .. '?base=' .. s.model.base
    b = vim.fn.bufnr(name)
  end
  if b == -1 then
    b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(b, name)
  end
  vim.b[b].git_blob_base = s.model.base
  utils.set_buf_work_tree(b, s.model.root)
  local oid = model_api.git(s.model.root, { 'rev-parse', '--verify', rev .. ':' .. path })
  vim.b[b].lazyagent_note_source = { kind = 'fugitive', root = s.model.root, path = path,
    git_dir = vim.b[s.buf].git_dir, revision = rev, blob = oid and vim.trim(oid), side = before and 'a' or 'b' }
  vim.bo[b].modifiable = true
  vim.api.nvim_buf_set_lines(b, 0, -1, false, content)
  vim.bo[b].bufhidden, vim.bo[b].buftype = 'wipe', 'nofile'
  vim.bo[b].modifiable, vim.bo[b].readonly = false, true
  vim.cmd("normal! m'")
  vim.api.nvim_win_set_buf(0, b)
  ordinary_window()
  vim.bo[b].filetype = vim.filetype.match({ filename = path }) or ''
  vim.keymap.set('n', 'C', function()
    require('git.features.commands').show_commit_info_float(rev, true, true)
  end, { buffer = b, silent = true, nowait = true, desc = 'Toggle blob commit information' })
  -- The right side compares with the selected parent, including renamed paths.
  if not entry.binary then objects.attach_gitsigns(b, s.model.root, path, s.model.base,
    before and path or (entry.old_path or path)) end
  return b
end
local function diff(s, layout)
  local entry, info = M.entry_at(s.buf, vim.fn.line('.'))
  if not entry then
    local args = s.model.base .. '..' .. s.model.hash
    vim.cmd('DiffviewOpen ' .. args); return
  end
  if entry.binary then vim.notify('Binary file; use D for Diffview', vim.log.levels.INFO); return end
  vim.cmd('tabnew')
  show_blob(s, entry, true)
  vim.cmd('diffthis')
  vim.cmd(layout == 'horizontal' and 'belowright split' or 'rightbelow vsplit')
  local b = show_blob(s, entry, false)
  if b then
    vim.cmd('diffthis')
    vim.api.nvim_win_set_cursor(0, { math.min(target_line(s, info), vim.api.nvim_buf_line_count(b)), 0 })
  end
  vim.cmd('wincmd =')
end
local function discard(s, first, last)
  if not clean_action(s) then return end
  local entry, info = M.entry_at(s.buf, first or vim.fn.line('.'))
  if not entry then notify('Select a changed file or hunk'); return end
  local patch, err = model_api.patch(s.model, entry)
  if not patch then notify(err); return end
  local scope, reverse = 'file', true
  local hunk
  if info.patch_row then
    for i = info.patch_row, 1, -1 do if patch[i]:match('^@@') then hunk = i; break end end
  end
  if first then
    local last_entry, last_info = M.entry_at(s.buf, last)
    if last_entry ~= entry or not hunk or not last_info.patch_row then notify('Select diff lines within one hunk'); return end
    for i = info.patch_row + 1, last_info.patch_row do
      if patch[i]:match('^@@') then notify('Select diff lines within one hunk'); return end
    end
    patch = actions.build_partial_reverse_patch(entry.path, patch, hunk, info.patch_row, last_info.patch_row)
    scope, reverse = 'selection', false
  elseif hunk then
    patch = actions.collect_hunk_patch(patch, 1, hunk)
    scope = 'hunk'
  end
  if not patch then notify('No changed lines selected'); return end
  local mode = actions.confirm_discard_mode(scope, s.model.hash)
  if not mode then return end
  local hash, warning = rewrite.apply(s.model.root, s.model.hash, {
    patch = patch, reverse = reverse, mixed = mode == 'mixed', expected_head = s.expected_head,
  })
  if not hash then notify(warning); return end
  replace_model(s, hash)
  focus_path(s, entry.path)
  if warning then vim.notify(warning, vim.log.levels.WARN) end
  if not warning and #s.model.entries == 0 and #s.model.parents < 2
    and vim.fn.confirm('Commit is now empty. Drop it?', '&Yes\n&No', 2) == 1 then
    local next_hash, drop_error = rewrite.apply(s.model.root, hash, { drop = true, expected_head = s.expected_head })
    if next_hash then replace_model(s, next_hash) end
    if drop_error then notify(drop_error) end
  end
end
local function open_related(s, revision, path)
  if not clean_action(s) then return end
  local b = M.open({ work_tree = s.model.root, revision = revision })
  if b and path then
    states[b].expanded[path] = true
    render(states[b]); focus_path(states[b], path)
  end
end
local function attach(s)
  local b = s.buf
  vim.api.nvim_buf_attach(b, false, { on_lines = function()
    -- Set this before a command checks whether it may hide a modified buffer.
    vim.bo[b].bufhidden = 'hide'
  end })
  local function map(keys, callback, opts)
    for _, key in ipairs(type(keys) == 'table' and keys or { keys }) do
      vim.keymap.set('n', key, function()
        -- Keep ordinary text editing available in the message region.
        if (opts or {}).native and in_message(s) then
          vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), 'n', false)
        else callback() end
      end, { buffer = b, silent = true, nowait = not (opts or {}).prefix, desc = (opts or {}).desc })
    end
  end
  map({ 'o', '=' }, function() toggle(s, 'toggle') end, { native = true })
  map('i', function() move(s, 1, true, false); vim.cmd('normal! zt') end, { native = true })
  map('>', function() toggle(s, 'show') end, { native = true })
  map('<', function() toggle(s, 'hide') end, { native = true })
  for key, mode in pairs({ ['='] = 'toggle', ['>'] = 'show', ['<'] = 'hide' }) do
    local chosen = mode
    vim.keymap.set('x', key, function()
      local first, last = math.min(vim.fn.line('v'), vim.fn.line('.')), math.max(vim.fn.line('v'), vim.fn.line('.'))
      vim.cmd('normal! \27')
      toggle(s, chosen, first, last)
    end, { buffer = b, silent = true })
  end
  map({ ']m', ']/', ')' }, function() move(s, 1, false, false) end)
  map({ '[m', '[/', '(' }, function() move(s, -1, false, false) end)
  map({ 'J', ']c' }, function() move(s, 1, true, false) end, { native = true })
  map({ 'K', '[c' }, function() move(s, -1, true, false) end, { native = true })
  map(']]', function() move(s, 1, false, true) end)
  map('[[', function() move(s, -1, false, true) end)
  map('d', function() diff(s, 'vertical') end, { native = true, prefix = true })
  map({ 'dd', 'dv' }, function() diff(s, 'vertical') end, { native = true })
  map({ 'dh', 'ds' }, function() diff(s, 'horizontal') end, { native = true })
  map('D', function() vim.cmd('DiffviewOpen ' .. s.model.base .. '..' .. s.model.hash) end, { native = true })
  map('<CR>', function()
    local entry, info = M.entry_at(b, vim.fn.line('.'))
    if not entry then return end
    if not clean_action(s) then return end
    local patch_line = info and info.patch_row and model_api.patch(s.model, entry)[info.patch_row]
    local before = entry.status == 'D' or (patch_line ~= nil and patch_line:sub(1, 1) == '-')
    local line = target_line(s, info, before)
    local buf = show_blob(s, entry, before)
    if buf then vim.api.nvim_win_set_cursor(0, { math.min(line, vim.api.nvim_buf_line_count(buf)), 0 }) end
  end)
  map('gf', function()
    local entry, info = M.entry_at(b, vim.fn.line('.'))
    if not entry or not clean_action(s) then return end
    vim.cmd('edit ' .. vim.fn.fnameescape(vim.fs.joinpath(s.model.root, entry.path)))
    vim.api.nvim_win_set_cursor(0, { math.min(target_line(s, info), vim.api.nvim_buf_line_count(0)), 0 })
  end)
  map('gq', function()
    local items = {}
    for _, entry in ipairs(s.model.entries) do items[#items + 1] = { filename = vim.fs.joinpath(s.model.root, entry.path), lnum = 1 } end
    vim.fn.setqflist({}, ' ', { title = s.model.hash, items = items }); vim.cmd('copen')
  end, { native = true })
  map({ 'A', 'cw' }, function()
    vim.api.nvim_win_set_cursor(0, { #s.prefix + 1, 0 })
    vim.cmd('startinsert')
  end, { native = true })
  map('gA', function()
    if not clean_action(s) then return end
    actions.open_edit_commit(s.model.hash, b, { reopen = false,
      rewrite_message = function(lines)
        if states[b] ~= s then return nil, 'The commit view has been closed' end
        return rewrite.apply(s.model.root, s.model.hash, { message = lines, expected_head = s.expected_head })
      end,
      on_complete = function(hash)
        if states[b] == s then replace_model(s, hash) end
      end,
    })
  end)
  map('X', function() discard(s) end, { native = true })
  vim.keymap.set('x', 'X', function()
    local first, last = math.min(vim.fn.line('v'), vim.fn.line('.')), math.max(vim.fn.line('v'), vim.fn.line('.'))
    vim.cmd('normal! \27'); discard(s, first, last)
  end, { buffer = b, silent = true })
  map('~', function() if s.model.parents[s.model.parent_index] then open_related(s, s.model.parents[s.model.parent_index]) end end, { native = true })
  map('p', function()
    local entry = M.entry_at(b, vim.fn.line('.'))
    if not entry then return end
    local hash = model_api.git(s.model.root, { '--literal-pathspecs', 'log', '--format=%H', '--skip=1', '-n', '1', s.model.hash, '--', entry.path })
    if hash and vim.trim(hash) ~= '' then open_related(s, vim.trim(hash), entry.path) end
  end, { native = true })
  map('gp', function()
    if #s.model.parents < 2 then return end
    vim.ui.select(s.model.parents, { prompt = 'Compare against parent:' }, function(_, index)
      if not index or states[b] ~= s then return end
      local current, err = message(s)
      if not current then notify(err); return end
      local model, load_err = model_api.load(s.model.root, s.model.hash, index)
      if not model then notify(load_err); return end
      s.model = model; render(s, current)
    end)
  end)
  map('<C-y>', function()
    vim.fn.setreg('"', s.model.hash:sub(1, 7)); vim.fn.setreg('+', s.model.hash:sub(1, 7))
  end)
  map('C', function() require('git.features.commands').show_commit_info_float(s.model.hash, true, true) end, { native = true })
  map('O', function() vim.cmd('OctoPrFromSha ' .. s.model.hash) end, { native = true })
  map('<C-Space>', function()
    if vim.g.flog_win and vim.api.nvim_win_is_valid(vim.g.flog_win) then
      vim.api.nvim_win_close(vim.g.flog_win, false)
      vim.g.flog_win, vim.g.flog_bufnr, vim.g.flog_opener_bufnr = nil, nil, nil
    else
      local win = vim.api.nvim_get_current_win()
      require('git.graph').open()
      vim.g.flog_bufnr, vim.g.flog_win, vim.g.flog_opener_bufnr = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win(), b
      utils.setup_flog_window(vim.g.flog_win, vim.g.flog_bufnr)
      utils.highlight_flog_commit(vim.g.flog_bufnr, vim.g.flog_win, s.model.hash)
      vim.api.nvim_set_current_win(win)
    end
  end)
  map('R', function()
    if not clean_action(s) then return end
    s.expanded = {}; replace_model(s, s.model.hash)
  end, { native = true })
  map('<Leader>wd', function() vim.notify('Word diff style: ' .. syntax.cycle_word_diff_style()) end)
  map('q', function()
    if message_dirty(s) then
      local choice = vim.fn.confirm('Save edited commit message?', '&Save\n&Discard\n&Cancel', 3)
      if choice == 1 then if not M.write(b) then return end
      elseif choice == 2 then render(s)
      else return end
    end
    close_inspection()
  end)
  map({ 'g?', '?' }, function()
    require('git.features.help').show_text('Commit view', {
      'Message: edit directly; :w rewrites the displayed commit (and descendants)',
      'A / cw   edit message',
      'gA       message float',
      'o / =    toggle diff',
      '> / <    expand / collapse',
      ']m / [m  next / previous file',
      'J / K    next / previous hunk',
      ']] / [[  move and expand file',
      'R        collapse / reload',
      '<CR>     committed file',
      'gf       worktree file',
      'd / dv   vertical diff',
      'dh       horizontal diff',
      'D        Diffview',
      'X        remove file / hunk / selected lines (Hard / Mixed)',
      '~        parent commit',
      'gp       select merge parent',
      'p        previous file commit',
      'C        commit info',
      '<C-Space>  graph',
      'O        pull request',
      'gq       quickfix',
      '<C-y>    copy hash',
      '<Leader>wd  word diff style',
      'Normal text editing keys retain their meaning inside the message.',
    })
  end)
  local group = vim.api.nvim_create_augroup('FugitiveCommitView' .. b, { clear = true })
  vim.api.nvim_create_autocmd('BufWriteCmd', { group = group, buffer = b, callback = function(ev)
    local name = buffer_name(s.model.root, s.model.hash, s.view_id)
    if ev.match ~= name then error('Use :w without a filename to reword this commit') end
    if not M.write(b) then error('Commit message was not saved') end
  end })
  vim.api.nvim_create_autocmd('BufWinEnter', { group = group, buffer = b, callback = function()
    configure_window()
    restore_view(s)
  end })
  vim.api.nvim_create_autocmd('WinLeave', { group = group, buffer = b, callback = function() remember_view(s) end })
  vim.api.nvim_create_autocmd('BufWinLeave', { group = group, buffer = b, callback = function()
    remember_view(s)
    -- Fugitive deletes clean hidden objects. A draft must survive window changes.
    vim.bo[b].bufhidden = vim.bo[b].modified and 'hide' or 'delete'
  end })
  vim.api.nvim_create_autocmd({ 'BufEnter', 'CursorMoved' }, { group = group, buffer = b, callback = function()
    utils.highlight_flog_commit(vim.g.flog_bufnr, vim.g.flog_win, s.model.hash)
    local commands = require('git.features.commands')
    if commands.schedule_update_preview then commands.schedule_update_preview(s.model.hash) end
  end })
  vim.api.nvim_create_autocmd({ 'BufUnload', 'BufWipeout' }, { group = group, buffer = b, once = true, callback = function()
    states[b] = nil
    if vim.g.flog_opener_bufnr == b and vim.g.flog_win and vim.api.nvim_win_is_valid(vim.g.flog_win) then
      close_flog()
    end
    pcall(vim.api.nvim_del_augroup_by_id, group)
  end })
  syntax.attach(b)
end
function M.open(opts)
  opts = opts or {}
  local root = opts.work_tree or utils.get_buf_work_tree(vim.api.nvim_get_current_buf()) or utils.get_work_tree({})
  if not root then notify('Not in a Git repository'); return end
  root = utils.normalize_path(root)
  local revision = opts.revision or 'HEAD'
  local saved = opts.bufnr and saved_views[opts.bufnr]
  local model, err = model_api.load(root, revision, opts.parent or (saved and saved.parent))
  if not model then notify(err); return end
  for b, s in pairs(states) do
    if not opts.bufnr and vim.api.nvim_buf_is_loaded(b) and s.model.root == root and s.model.hash == model.hash and s.model.parent_index == model.parent_index then
      if opts.tab then vim.cmd('tabnew') elseif opts.split then vim.cmd('belowright split') end
      show_buffer(b); configure_window(); return b
    end
  end
  local b = opts.bufnr or vim.api.nvim_create_buf(true, false)
  serial = serial + 1
  local view_id = opts.view_id or serial
  vim.api.nvim_buf_set_name(b, buffer_name(root, model.hash, view_id))
  vim.bo[b].buflisted = true
  vim.bo[b].buftype, vim.bo[b].bufhidden, vim.bo[b].swapfile = 'acwrite', 'delete', false
  vim.bo[b].undofile = false
  utils.set_buf_work_tree(b, root)
  vim.b[b].fugitive_commit = model.hash
  vim.b[b].custom_git_commit = true
  local s = { buf = b, view_id = view_id, model = model, expanded = saved and vim.deepcopy(saved.expanded) or {}, expected_head = vim.trim(model_api.git(root, { 'rev-parse', 'HEAD' }) or '') }
  states[b] = s
  render(s)
  if opts.tab then vim.cmd('tabnew') elseif opts.split then vim.cmd('belowright split') end
  show_buffer(b)
  vim.bo[b].filetype = 'fugitivecommit'
  vim.bo[b].syntax = 'git'
  configure_window(); attach(s)
  if saved then
    restore_view(s)
    local win = vim.api.nvim_get_current_win()
    -- Jump commands finish positioning after BufReadCmd returns.
    vim.schedule(function()
      if states[b] == s and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == b then
        vim.api.nvim_win_call(win, function() restore_view(s) end)
      end
    end)
  else
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
  end
  return b
end
function M.open_edit_commit(commit, origin_buf, opts)
  local s = state(origin_buf)
  if s then
    if not clean_action(s) then return end
    vim.api.nvim_win_set_cursor(0, { #s.prefix + 1, 0 }); vim.cmd('startinsert'); return
  end
  return actions.open_edit_commit(commit, origin_buf, opts)
end
M._close_edit_float = actions._close_edit_float
M._do_amend_from_buffer = actions._do_amend_from_buffer
function M.setup(group)
  vim.api.nvim_create_autocmd('BufEnter', { group = group, callback = function(ev)
    local win = vim.api.nvim_get_current_win()
    local return_win = vim.w[win].fugitive_commit_return_win
    if not return_win or return_win == win or not vim.api.nvim_win_is_valid(return_win)
      or vim.api.nvim_win_get_buf(return_win) ~= ev.buf then return end
    -- Jump lists can pass through blobs or tabnew's placeholder, where commit
    -- mappings are absent. Redirect only once the actual origin is reached.
    vim.schedule(function()
      if vim.api.nvim_get_current_win() == win and vim.api.nvim_win_is_valid(return_win)
        and vim.api.nvim_get_current_buf() == ev.buf
        and vim.api.nvim_win_get_buf(return_win) == ev.buf then
        close_inspection()
      end
    end)
  end })
  vim.api.nvim_create_autocmd('BufWipeout', { group = group, callback = function(ev) saved_views[ev.buf] = nil end })
  vim.api.nvim_create_autocmd('BufReadCmd', { group = group, pattern = 'git-commit://*', callback = function(ev)
    local root, id, hash = ev.match:match('^git%-commit://(.*)/(%d+)/(%x+)$')
    if not root then error('Invalid commit URI') end
    M.open({ work_tree = root, revision = hash, bufnr = ev.buf, view_id = tonumber(id) })
  end })
  vim.api.nvim_create_user_command('GitCommit', function(args)
    M.open({ revision = args.args ~= '' and args.args or 'HEAD' })
  end, { nargs = '?', complete = require('git.completion').refs, desc = 'Open commit detail' })
end
return M
