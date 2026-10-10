-- Editable PR metadata above an immutable, lazily expanded merge-base diff.
local M = {}
local utils = require('git.utils')
local github = require('git.features.github')
local actions = require('git.features.github_actions')
local model_api = require('git.features.pr_model')
local changes = require('git.features.commit_model')
local display = require('git.features.change_display')
local syntax = require('git.features.syntax_highlight')
local states = {}
local window_options = {}
local ns = vim.api.nvim_create_namespace('git_pr_status')
local function configure_window(win)
  local options = { number = false, relativenumber = false, wrap = false, foldenable = false, list = false }
  if not window_options[win] then
    window_options[win] = {}
    for name in pairs(options) do window_options[win][name] = vim.api.nvim_get_option_value(name, { win = win, scope = 'local' }) end
  end
  for name, value in pairs(options) do vim.api.nvim_set_option_value(name, value, { win = win, scope = 'local' }) end
end
local function restore_window(win)
  local saved = window_options[win]
  window_options[win] = nil
  if saved and vim.api.nvim_win_is_valid(win) then
    for name, value in pairs(saved) do vim.api.nvim_set_option_value(name, value, { win = win, scope = 'local' }) end
  end
end
local window_group = vim.api.nvim_create_augroup('GitPrWindows', { clear = true })
vim.api.nvim_create_autocmd('BufWinEnter', { group = window_group, callback = function(ev)
  local win = vim.api.nvim_get_current_win()
  if states[ev.buf] then configure_window(win) else restore_window(win) end
end })
vim.api.nvim_create_autocmd('WinClosed', { group = window_group, callback = function(ev) window_options[tonumber(ev.match)] = nil end })
local function notify(err) vim.notify(tostring(err), vim.log.levels.ERROR) end
function M.model(buf) local s = states[buf or vim.api.nvim_get_current_buf()]; return s and s.model end
local function live(s) return states[s.buf] == s and vim.api.nvim_buf_is_loaded(s.buf) end
local function draft(s)
  local lines = vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)
  if #lines < #s.prefix + #s.suffix + 2 then return nil, 'Only the PR title and description may be edited' end
  for i, line in ipairs(s.prefix) do
    if lines[i] ~= line then return nil, 'PR metadata is read-only; undo those edits before saving' end
  end
  local tail = #lines - #s.suffix
  for i, line in ipairs(s.suffix) do
    if lines[tail + i] ~= line then return nil, 'PR diffs are read-only; undo those edits before saving' end
  end
  local editable = vim.list_slice(lines, #s.prefix + 1, tail)
  if not editable[1] or vim.trim(editable[1]) == '' then return nil, 'PR title cannot be empty' end
  if editable[2] ~= '' then return nil, 'Keep a blank line between the PR title and description' end
  return editable
end
local function edited(s)
  local current = draft(s)
  return not current or not vim.deep_equal(current, s.original)
end
local function delta(s) return vim.api.nvim_buf_line_count(s.buf) - s.line_count end
function M.entry_at(buf, row)
  local s = states[buf]
  if not s or not s.model then return nil end
  local info = s.rows[row - delta(s)]
  return info and info.entry, info
end
local function editable_row(s, row)
  return row > #s.prefix and row <= vim.api.nvim_buf_line_count(s.buf) - #s.suffix
end
local function render(s, current)
  local model, pr = s.model, s.model.pr
  local prefix = {
    ('PR #%d · %s%s'):format(pr.number, pr.state or 'OPEN', pr.isDraft and ' [draft]' or ''),
    ('%s ← %s · @%s'):format(pr.baseRefName, pr.headRefName, pr.author and pr.author.login or 'unknown'),
    github.summary(pr), 'Merge: ' .. (pr.mergeStateStatus ~= vim.NIL and pr.mergeStateStatus or 'UNKNOWN'),
    pr.url,
  }
  s.links = { [3] = pr.url .. '/checks' }
  for _, check in ipairs(github.checks(pr)) do
    prefix[#prefix + 1] = '  CI · ' .. check.label:gsub('[\r\n]', ' ')
    s.links[#prefix] = check.url or pr.url .. '/checks'
  end
  prefix[#prefix + 1] = 'GitHub Actions · gx opens branch runs'
  s.links[#prefix] = github.actions_url(model.ctx, pr.headRefName)
  vim.list_extend(prefix, { '', 'Title / description · edit below, :w saves to GitHub' })
  local original = { pr.title, '' }
  if pr.body and pr.body ~= '' and pr.body ~= vim.NIL then vim.list_extend(original, vim.split(pr.body, '\n', { plain = true })) end
  local message = current or original
  local lines = vim.list_extend(vim.deepcopy(prefix), message)
  local suffix_start = #lines + 1
  vim.list_extend(lines, { '', ('Changes (%d) · merge-base %s → %s'):format(#model.entries, model.base:sub(1, 7), model.hash:sub(1, 7)) })
  if model.comments_error then lines[#lines + 1] = 'Comments unavailable: ' .. model.comments_error:gsub('[\r\n]', ' ') end
  local rows = {}
  for _, entry in ipairs(model.entries) do
    lines[#lines + 1] = display.line(entry)
    rows[#lines] = { entry = entry, header = true, threads = model_api.threads_at(model, entry) }
    if s.expanded[entry.path] then
      local diff, start = changes.inline(model, entry)
      if not diff then notify(start); diff = { 'Diff unavailable; refresh to retry' } end
      local coordinates = entry.patch and model_api.coordinates(entry.patch) or {}
      for i, line in ipairs(diff) do
        local patch_row = start and start + i - 1
        lines[#lines + 1] = line
        rows[#lines] = { entry = entry, patch_row = patch_row, coordinate = coordinates[patch_row],
          threads = coordinates[patch_row] and model_api.threads_at(model, entry, coordinates[patch_row]) or {} }
      end
    end
  end
  -- File/outdated comments are also accessible without a matching displayed line.
  vim.list_extend(lines, { '', ('Review threads (%d) · gc opens / replies; O reviews in Octo'):format(#model.threads) })
  s.prefix, s.suffix, s.original = prefix, vim.list_slice(lines, suffix_start), original
  s.rows, s.line_count = rows, #lines
  local old = vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)
  local first, tail = 0, 0
  while first < math.min(#old, #lines) and old[first + 1] == lines[first + 1] do first = first + 1 end
  while tail < math.min(#old, #lines) - first and old[#old - tail] == lines[#lines - tail] do tail = tail + 1 end
  vim.bo[s.buf].modifiable = true
  if first < #old or first < #lines then
    vim.api.nvim_buf_set_lines(s.buf, first, #old - tail, false, vim.list_slice(lines, first + 1, #lines - tail))
  end
  vim.bo[s.buf].modified = not vim.deep_equal(message, original)
  vim.api.nvim_buf_clear_namespace(s.buf, ns, 0, -1)
  for _, row in ipairs({ 1, 3, 4, #prefix, suffix_start + 1, #lines }) do
    vim.api.nvim_buf_set_extmark(s.buf, ns, row - 1, 0, { end_col = #lines[row], hl_group = row == 3 and 'DiagnosticInfo' or 'Title' })
  end
  for row, info in pairs(rows) do
    local chunks = info.header and display.statistics(info.entry) or {}
    if #info.threads > 0 then chunks[#chunks + 1] = { ' 💬 ' .. #info.threads, 'DiagnosticInfo' } end
    if #chunks > 0 then vim.api.nvim_buf_set_extmark(s.buf, ns, row - 1, 0, { virt_text = chunks, virt_text_pos = 'eol' }) end
    if info.header then
      local group = info.entry.status == 'A' and 'GitSignsAdd' or info.entry.status == 'D' and 'GitSignsDelete' or 'Structure'
      vim.api.nvim_buf_set_extmark(s.buf, ns, row - 1, 0, { end_col = 1, hl_group = group })
      local icon, hl = utils.get_devicon(info.entry.path)
      vim.api.nvim_buf_set_extmark(s.buf, ns, row - 1, 2, { virt_text = { { icon .. ' ', hl } }, virt_text_pos = 'inline' })
    end
  end
  syntax.refresh(s.buf)
end
local function focus(s, path)
  for row, info in pairs(s.rows) do if info.header and info.entry.path == path then
    vim.api.nvim_win_set_cursor(0, { row + delta(s), 0 }); return
  end end
end
local function toggle(s, mode, first, last, done)
  local current, err = draft(s)
  if not current then notify(err); return end
  local paths = {}
  for row = first or vim.fn.line('.'), last or vim.fn.line('.') do
    local entry = M.entry_at(s.buf, row)
    if entry then paths[entry.path] = entry end
  end
  if vim.tbl_isempty(paths) then for _, entry in ipairs(s.model.entries) do paths[entry.path] = entry end end
  local cursor = M.entry_at(s.buf, vim.fn.line('.'))
  local expanded = vim.deepcopy(s.expanded)
  local missing = false
  for path, entry in pairs(paths) do
    expanded[path] = mode == 'show' or (mode == 'toggle' and not s.expanded[path])
    if expanded[path] and not entry.patch then missing = true end
  end
  if missing then
      if s.expanding then return end
      s.expanding = true
      local task = require('git.features.async').run(s.model.root, function()
        for pending, item in pairs(paths) do if expanded[pending] then
          local patch, failure = changes.patch(s.model, item)
          if not patch then error(failure, 0) end
        end end
      end, function(ok, failure)
        s.expanding = false
        if not live(s) then return end
        if not ok then notify(failure); return end
        local latest, read_err = draft(s)
        if not latest then notify(read_err); return end
        s.expanded = expanded; render(s, latest)
        if cursor then focus(s, cursor.path) end
        if done then done() end
      end)
      s.patch_task = task
      return
  end
  s.expanded = expanded; render(s, current)
  if cursor then focus(s, cursor.path) end
  if done then done() end
end
local function move(s, direction, hunks, expand)
  local entry = M.entry_at(s.buf, vim.fn.line('.'))
  if hunks and entry and not s.expanded[entry.path] then
    toggle(s, 'show', nil, nil, function() move(s, direction, hunks, expand) end)
    return
  end
  local row, lines = vim.fn.line('.'), vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)
  local candidates = {}
  for at, info in pairs(s.rows) do
    local target = at + delta(s)
    if (target - row) * direction > 0 and (hunks and lines[target]:match('^@@') or not hunks and info.header) then
      candidates[#candidates + 1] = target
    end
  end
  table.sort(candidates, function(a, b) return direction > 0 and a < b or direction < 0 and a > b end)
  local target = candidates[math.min(vim.v.count1, #candidates)]
  if target then vim.api.nvim_win_set_cursor(0, { target, 0 }); if expand then toggle(s, 'show') end end
end
local function comments(s)
  local _, info = M.entry_at(s.buf, vim.fn.line('.'))
  require('git.features.pr_threads').select(s.model.ctx, info and info.threads or s.model.threads)
end
local function blob(s, entry, before, coordinate)
  local path = before and (entry.old_path or entry.path) or entry.path
  local revision = before and s.model.base or s.model.hash
  local missing = before and entry.status == 'A' or not before and entry.status == 'D'
  local content, err = '', nil
  if not missing then content, err = changes.git(s.model.root, { 'show', revision .. ':' .. path }) end
  if not content then notify(err); return end
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(b, ('git-pr-blob://%d/%s/%s'):format(b, revision, path))
  vim.bo[b].buftype, vim.bo[b].bufhidden, vim.bo[b].swapfile = 'nofile', 'wipe', false
  vim.api.nvim_buf_set_lines(b, 0, -1, false, changes.lines(content))
  vim.bo[b].modifiable, vim.bo[b].readonly = false, true
  utils.set_buf_work_tree(b, s.model.root)
  vim.api.nvim_win_set_buf(0, b)
  vim.bo[b].filetype = vim.filetype.match({ filename = path }) or ''
  vim.wo.wrap = false
  if coordinate then
    local line = before and coordinate.left or nil
    if not before then line = coordinate.right end
    if line then vim.api.nvim_win_set_cursor(0, { math.max(1, math.min(line, vim.api.nvim_buf_line_count(b))), 0 }) end
  end
  vim.keymap.set('n', 'q', function() if #vim.api.nvim_list_tabpages() > 1 then vim.cmd('tabclose') else vim.cmd('close') end end,
    { buffer = b, silent = true })
  return b
end
local function diff(s, horizontal)
  local entry, info = M.entry_at(s.buf, vim.fn.line('.'))
  if not entry then M.diffview(s.buf); return end
  if entry.binary then M.diffview(s.buf, entry.path); return end
  vim.cmd('tabnew')
  blob(s, entry, true, info.coordinate); vim.cmd('diffthis')
  local left = vim.api.nvim_get_current_win()
  vim.cmd(horizontal and 'belowright split' or 'rightbelow vsplit')
  blob(s, entry, false, info.coordinate); vim.cmd('diffthis')
  require('git.features.split_diff').attach(left, vim.api.nvim_get_current_win())
  vim.cmd('wincmd =')
end
function M.diffview(buf, path)
  local s = states[buf]
  if not s or not s.model then return end
  vim.api.nvim_buf_call(buf, function()
    -- Diffview resolves its repository from cwd, so use its explicit -C flag.
    local args = { '-C=' .. s.model.root, s.model.base .. '..' .. s.model.hash }
    if path then vim.list_extend(args, { '--', path }) end
    vim.api.nvim_cmd({ cmd = 'DiffviewOpen', args = args }, {})
  end)
end
function M.refresh(buf, discard)
  local s = states[buf]
  if not s or s.loading or s.saving or s.expanding then return end
  if s.model and edited(s) then
    if not discard then vim.notify('Save or undo the PR draft before refreshing', vim.log.levels.WARN); return end
    render(s)
  end
  s.loading = true
  local expected = s.model
  s.task = actions.run(vim.tbl_extend('force', s.ctx, { notify_change = false }), model_api.load, function(model)
    s.loading = false
    if not live(s) or s.model ~= expected then return end
    -- An edit made during the network request must survive.
    local current = s.model and draft(s) or nil
    if s.model and not current then notify('PR changed locally during refresh; undo protected edits and refresh'); return end
    local dirty = s.model and edited(s)
    if not dirty then s.metadata_conflict = false
    elseif s.model.pr.title ~= model.pr.title or s.model.pr.body ~= model.pr.body then s.metadata_conflict = true end
    s.model, s.ctx = model, model.ctx
    render(s, dirty and current or nil)
  end, true, function(err)
    s.loading = false
    if live(s) and not s.model then
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'Could not load PR: ' .. tostring(err):gsub('[\r\n]', ' '), 'R retries · q closes' })
      vim.bo[buf].modifiable, vim.bo[buf].modified = false, false
    end
  end)
end
function M.write(buf)
  local s = states[buf]
  if not s or not s.model then return end
  if s.saving or s.loading then error('A PR request is already running') end
  if s.metadata_conflict then error('PR metadata changed during refresh; preserve your draft and reload before saving') end
  local current, err = draft(s)
  if not current then error(err) end
  if not edited(s) then vim.bo[buf].modified = false; return end
  local title, body = current[1], table.concat(vim.list_slice(current, 3), '\n')
  local original = s.model.pr
  s.saving = true
  actions.run(s.ctx, function(ctx)
    local remote = github.pr(ctx)
    if remote.title ~= original.title or (remote.body or '') ~= (original.body or '') then
      error('PR title/description changed on GitHub; preserve your draft and reload before overwriting', 0)
    end
    return github.json(ctx, { 'api', '--hostname', ctx.host, '--method', 'PATCH',
      ('repos/%s/pulls/%d'):format(ctx.repo, ctx.number), '--input', '-' }, { stdin = vim.json.encode({ title = title, body = body }) })
  end, function()
    s.saving = false
    if not live(s) then return end
    local latest = draft(s)
    s.model.pr.title, s.model.pr.body = title, body
    if latest then render(s, latest) end
    vim.notify('PR title and description saved')
  end, true, function() s.saving = false end)
end
local function attach(s)
  local b = s.buf
  local function map(keys, fn, description, native)
    for _, key in ipairs(type(keys) == 'table' and keys or { keys }) do
      vim.keymap.set('n', key, function()
        if not s.model then return end
        if native and editable_row(s, vim.fn.line('.')) then
          vim.cmd.normal({ args = { key }, bang = true }); return
        end
        fn()
      end, { buffer = b, silent = true, nowait = not vim.tbl_contains({ 'd', 'g', '[', ']' }, key), desc = description })
    end
  end
  map({ 'o', '=', '<Tab>' }, function() toggle(s, 'toggle') end, 'Toggle PR file diff', true)
  map('>', function() toggle(s, 'show') end, 'Expand PR file diffs', true)
  map('<', function() toggle(s, 'hide') end, 'Collapse PR file diffs', true)
  for _, key in ipairs({ 'o', '=', '>', '<' }) do
    local mode = ({ o = 'toggle', ['='] = 'toggle', ['>'] = 'show', ['<'] = 'hide' })[key]
    vim.keymap.set('x', key, function()
      local first, last = math.min(vim.fn.line('v'), vim.fn.line('.')), math.max(vim.fn.line('v'), vim.fn.line('.'))
      if editable_row(s, first) then vim.cmd.normal({ args = { key }, bang = true }); return end
      vim.cmd('normal! \27'); toggle(s, mode, first, last)
    end, { buffer = b, silent = true, desc = 'Toggle / expand / collapse selected PR files' })
  end
  map({ ']m', ']/' }, function() move(s, 1) end, 'Next PR file')
  map({ '[m', '[/' }, function() move(s, -1) end, 'Previous PR file')
  map(']]', function() move(s, 1, false, true) end, 'Next file and expand')
  map('[[', function() move(s, -1, false, true) end, 'Previous file and expand')
  map({ 'J', ']c' }, function() move(s, 1, true) end, 'Next PR hunk', true)
  map({ 'K', '[c' }, function() move(s, -1, true) end, 'Previous PR hunk', true)
  map({ 'd', 'dd', 'dv' }, function() diff(s) end, 'Compare selected PR file', true)
  map({ 'dh', 'ds' }, function() diff(s, true) end, 'Compare PR file horizontally')
  map('D', function() M.diffview(b) end, 'Open entire PR in Diffview', true)
  map('gc', function() comments(s) end, 'Open review thread / reply')
  map('<CR>', function()
    local entry, info = M.entry_at(b, vim.fn.line('.'))
    if info and #info.threads > 0 then comments(s)
    elseif entry then blob(s, entry, false, info.coordinate) end
  end, 'Open thread or PR head file', true)
  map('gf', function()
    local entry = M.entry_at(b, vim.fn.line('.'))
    if entry then
      local path = utils.worktree_relative_abs_path(s.model.root, entry.path)
      if path then vim.cmd('edit ' .. vim.fn.fnameescape(path)) end
    end
  end, 'Open worktree file')
  map({ 'cw', 'A' }, function() vim.api.nvim_win_set_cursor(0, { #s.prefix + 1, 0 }); vim.cmd('startinsert') end, 'Edit PR title / description', true)
  map('O', function() actions.octo(s.ctx, true) end, 'Review PR in Octo', true)
  map('gx', function()
    local _, info = M.entry_at(b, vim.fn.line('.'))
    local thread = info and info.threads[1]
    vim.ui.open(s.links[vim.fn.line('.')] or (thread and thread.url) or s.ctx.url)
  end, 'Open PR / CI check / Actions / comment on GitHub')
  map('gy', function() vim.fn.setreg('"', s.ctx.url); pcall(vim.fn.setreg, '+', s.ctx.url) end, 'Copy PR URL')
  map('gq', function()
    local items = {}
    for _, entry in ipairs(s.model.entries) do
      local path = utils.worktree_relative_abs_path(s.model.root, entry.path)
      if path then items[#items + 1] = { filename = path, lnum = 1 } end
    end
    vim.fn.setqflist({}, ' ', { title = 'PR #' .. s.ctx.number, items = items }); vim.cmd('copen')
  end, 'PR files in quickfix')
  map('gD', function()
    local choices = {}
    for _, style in ipairs({ 'delta', 'github', 'diffs', 'treesitter' }) do
      choices[#choices + 1] = { key = style:sub(1, 1), label = style, run = function() syntax.set_word_diff_style(style) end }
    end
    choices[1].key = 'l'
    require('git.features.transient_menu').show({ kind = 'pr-display', title = 'PR diff display',
      groups = { { title = 'Word diff', actions = choices } } })
  end, 'PR diff display settings')
  -- Loading and failed requests still need an exit even without a model.
  vim.keymap.set('n', 'q', function()
    if s.model and edited(s) and vim.fn.confirm('Discard unsaved PR title/description?', '&Discard\n&Keep', 2) ~= 1 then return end
    vim.api.nvim_buf_delete(b, { force = true })
  end, { buffer = b, silent = true, desc = 'Close PR status' })
  vim.keymap.set('n', 'R', function()
    if s.model and editable_row(s, vim.fn.line('.')) then vim.cmd('normal! R'); return end
    if s.model and edited(s) then
      if vim.fn.confirm('Discard PR draft and reload from GitHub?', '&Reload\n&Keep', 2) ~= 1 then return end
      M.refresh(b, true)
    else M.refresh(b) end
  end, { buffer = b, silent = true, desc = 'Refresh PR status' })
  map('?', function() require('git.features.help').show_text('PR status', {
    'cw / A   edit title and description; :w saves to GitHub',
    'o / = / Tab  toggle diff; > / < expand / collapse (Visual supported)',
    ']m / [m files; ]] / [[ move and expand; J / K or ]c / [c hunks',
    'd / dv   vertical diff; dh horizontal; D entire PR in Diffview',
    '<CR>     open comment thread (if present) or PR head file; gf worktree file',
    'gc       read / reply to review threads; select file or a marked diff line',
    'O        review in Octo; N / <Space><Space> GitHub actions',
    'R refresh; gx browser; gy copy URL; gq quickfix; gD diff display; q close',
    'Only the title and description are editable; PR diffs are review snapshots.',
    'File/outdated threads remain accessible through their file header or gc.',
  }) end, 'PR status key guide')
  actions.attach(b)
  vim.keymap.set('n', '<Space><Space>', function() actions.open(s.ctx) end,
    { buffer = b, silent = true, desc = 'GitHub action menu' })
  local group = vim.api.nvim_create_augroup('GitPr' .. b, { clear = true })
  vim.api.nvim_create_autocmd('BufWriteCmd', { group = group, buffer = b, callback = function(ev)
    if ev.match ~= vim.api.nvim_buf_get_name(b) then error('Use :w without a filename to save PR metadata') end
    M.write(b)
  end })
  vim.api.nvim_create_autocmd('User', { group = group, pattern = 'GitHubChanged', callback = function(ev)
    local ctx = ev.data or {}
    if s.model and ctx.host == s.ctx.host and ctx.repo == s.ctx.repo and (not ctx.number or ctx.number == s.ctx.number) then
      M.refresh(b)
    end
  end })
  vim.api.nvim_create_autocmd('BufWipeout', { group = group, buffer = b, once = true, callback = function()
    states[b] = nil
    if s.patch_task then s.patch_task.cancel() end
    pcall(vim.api.nvim_del_augroup_by_id, group)
  end })
  syntax.attach(b, { diff_source = function(hunk)
    return s.model and changes.highlight_source(s.model, M.entry_at(b, hunk.start_line))
  end, prefetch = function()
    local specs = {}
    for _, entry in ipairs(s.model and s.model.entries or {}) do
      local spec = changes.highlight_source(s.model, entry)
      if spec then specs[#specs + 1] = { filename = entry.path, spec = spec } end
    end
    return specs
  end })
end
function M.open(opts)
  opts = vim.deepcopy(opts or {})
  opts.root = opts.root or utils.get_buf_work_tree(vim.api.nvim_get_current_buf()) or utils.get_work_tree({})
  if not opts.root then notify('Not in a Git repository'); return end
  local identity = opts.url or (opts.root .. '/' .. tostring(opts.number or 'current'))
  for b, s in pairs(states) do if s.identity == identity and vim.api.nvim_buf_is_loaded(b) then
    local win = vim.fn.bufwinid(b)
    if win ~= -1 then vim.api.nvim_set_current_win(win) else utils.open_panel_split(); vim.api.nvim_win_set_buf(0, b) end
    return b
  end end
  local b = vim.api.nvim_create_buf(true, false)
  local s = { buf = b, ctx = opts, identity = identity, expanded = {} }
  states[b] = s
  vim.api.nvim_buf_set_name(b, 'git-pr://' .. b .. '/' .. identity)
  vim.bo[b].buftype, vim.bo[b].bufhidden, vim.bo[b].swapfile, vim.bo[b].undofile = 'acwrite', 'hide', false, false
  utils.set_buf_work_tree(b, opts.root)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { 'Loading PR metadata and revisions…' })
  vim.bo[b].modified, vim.bo[b].modifiable = false, false
  utils.open_panel_split(); vim.api.nvim_win_set_buf(0, b)
  vim.bo[b].filetype, vim.bo[b].syntax = 'gitpr', 'git'
  configure_window(vim.api.nvim_get_current_win())
  attach(s); M.refresh(b)
  return b
end
function M.setup()
  vim.api.nvim_create_user_command('GitPr', function(args)
    local opts = {}
    if args.args ~= '' then
      if github.url_context(args.args) then opts.url = args.args
      elseif tonumber(args.args) then opts.number = tonumber(args.args)
      else notify('Use :GitPr [PR number or URL]'); return end
    end
    M.open(opts)
  end, { nargs = '?', desc = 'Open editable PR status and diffs' })
end
return M
