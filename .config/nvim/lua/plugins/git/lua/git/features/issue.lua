-- Editable Issue title/body above an immutable conversation and activity log.
local M = {}
local github = require('git.features.github')
local actions = require('git.features.github_actions')
local model = require('git.features.issue_model')
local utils = require('git.utils')
local markdown = require('git.features.pr_markdown')
local states, windows = {}, {}
local ns = vim.api.nvim_create_namespace('git_issue')
local title_ns = vim.api.nvim_create_namespace('git_issue_title')
local function notify(err) vim.notify(tostring(err), vim.log.levels.ERROR) end
local function live(s) return states[s.buf] == s and vim.api.nvim_buf_is_loaded(s.buf) end
local function message(issue)
  local lines = { issue.title, '' }
  if issue.body and issue.body ~= '' and issue.body ~= vim.NIL then vim.list_extend(lines, vim.split(issue.body, '\n', { plain = true })) end
  return lines
end
local function draft(s)
  local lines = vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)
  if #lines < #s.prefix + #s.suffix + 2 then return nil, 'Only the Issue title and body may be edited' end
  for i, line in ipairs(s.prefix) do if lines[i] ~= line then return nil, 'Issue header is read-only' end end
  local last = #lines - #s.suffix
  for i, line in ipairs(s.suffix) do if lines[last + i] ~= line then return nil, 'Issue conversation is read-only' end end
  return vim.list_slice(lines, #s.prefix + 1, last)
end
local function dirty(s) return s.model and not vim.deep_equal(draft(s), s.original) end
local function offset(s) return vim.api.nvim_buf_line_count(s.buf) - s.line_count end
local function editable(s, row)
  return s.model and row > #s.prefix and row <= vim.api.nvim_buf_line_count(s.buf) - #s.suffix
end
function M.model(buf) local s = states[buf or vim.api.nvim_get_current_buf()]; return s and s.model end
function M.conversation_at(buf, row)
  local s = states[buf]; return s and s.model and s.rows[row - offset(s)]
end
local function paint(s)
  vim.api.nvim_buf_clear_namespace(s.buf, title_ns, 0, -1)
  local title = vim.api.nvim_buf_get_lines(s.buf, #s.prefix, #s.prefix + 1, false)[1] or ''
  vim.api.nvim_buf_set_extmark(s.buf, title_ns, #s.prefix, 0,
    { end_col = #title, hl_group = 'Title', right_gravity = false, end_right_gravity = true })
  local ranges = { { #s.prefix + 2, vim.api.nvim_buf_line_count(s.buf) - #s.suffix } }
  for _, range in ipairs(s.markdown_ranges) do ranges[#ranges + 1] = { range[1] + offset(s), range[2] + offset(s) } end
  markdown.update(s.buf, ranges)
end
local function render(s, current)
  s.rendering = true
  markdown.prepare(s.buf)
  local issue, prefix, highlights = s.model.issue, {}, {}
  s.metadata_rows = {}
  local function add(label, value, field)
    prefix[#prefix + 1] = label .. value
    highlights[#highlights + 1] = { row = #prefix, start = 0, finish = #label, group = 'GitPrHeaderLabel' }
    if field then s.metadata_rows[#prefix] = field end
  end
  add('Repo: ', s.ctx.repo .. ' · ' .. s.ctx.host)
  if s.header_expanded then
    add('Issue: ', '#' .. s.ctx.number .. ' · ' .. issue.state
      .. (github.scalar(issue.state_reason) and (' · ' .. issue.state_reason) or '') .. ' · @' .. (issue.author.login or 'unknown'))
    local labels, assignees = {}, {}
    for _, item in ipairs(github.scalar(issue.labels) or {}) do labels[#labels + 1] = type(item) == 'string' and item or item.name end
    for _, item in ipairs(github.scalar(issue.assignees) or {}) do assignees[#assignees + 1] = '@' .. item.login end
    add('Labels: ', #labels > 0 and table.concat(labels, ', ') or '—', 'labels')
    add('Assignees: ', #assignees > 0 and table.concat(assignees, ', ') or '—', 'assignees')
    add('URL: ', s.ctx.url)
    if s.model.viewer_error then add('Viewer unavailable: ', s.model.viewer_error:gsub('[\r\n]', ' ')) end
  end
  vim.list_extend(prefix, { '', 'Title / body · edit below, <C-s> / :w saves to GitHub' })
  s.original = message(s.baseline)
  current = current or s.original
  local lines = vim.list_extend(vim.deepcopy(prefix), current)
  local suffix_start = #lines + 1
  local history = s.model.conversation
  vim.list_extend(lines, { '', ('Conversation (%d)%s'):format(#history.entries, #history.errors > 0 and ' · incomplete' or '') })
  s.conversation_row = #lines
  s.rows, s.markdown_ranges, s.first_item = {}, {}, nil
  if s.conversation_expanded then
    s.rows, s.first_item, s.markdown_ranges = require('git.features.pr_conversation').append(lines, highlights,
      history, s.model.viewer, markdown.active(s.buf), { empty = 'No Issue comments or activity.' })
  end
  s.prefix, s.suffix, s.line_count = prefix, vim.list_slice(lines, suffix_start), #lines
  vim.bo[s.buf].modifiable = true
  -- A minimal replacement keeps unchanged draft rows and native undo usable.
  local old, first, tail = vim.api.nvim_buf_get_lines(s.buf, 0, -1, false), 0, 0
  while first < math.min(#old, #lines) and old[first + 1] == lines[first + 1] do first = first + 1 end
  while tail < math.min(#old, #lines) - first and old[#old - tail] == lines[#lines - tail] do tail = tail + 1 end
  if first < #old or first < #lines then
    vim.api.nvim_buf_set_lines(s.buf, first, #old - tail, false, vim.list_slice(lines, first + 1, #lines - tail))
  end
  vim.bo[s.buf].modified = not vim.deep_equal(current, s.original)
  vim.api.nvim_buf_clear_namespace(s.buf, ns, 0, -1)
  for _, row in ipairs({ 1, #prefix, s.conversation_row }) do
    vim.api.nvim_buf_set_extmark(s.buf, ns, row - 1, 0, { end_col = #lines[row], hl_group = 'Title' })
  end
  for _, pair in ipairs({ { 1, s.header_expanded }, { s.conversation_row, s.conversation_expanded } }) do
    vim.api.nvim_buf_set_extmark(s.buf, ns, pair[1] - 1, 0,
      { sign_text = pair[2] and '▾' or '▸', sign_hl_group = 'GitPrHeaderLabel' })
  end
  for _, mark in ipairs(highlights) do
    vim.api.nvim_buf_set_extmark(s.buf, ns, mark.row - 1, mark.start,
      { end_col = mark.finish, hl_group = mark.group, priority = mark.priority or 200 })
  end
  paint(s)
  s.rendering = false
  if s.edit_guard then s.edit_guard.sync() end
end
function M.refresh(buf)
  local s = states[buf]
  if not s then return end
  if s.task then s.task.cancel() end
  s.generation = (s.generation or 0) + 1
  local generation = s.generation
  s.task = actions.run(s.ctx, model.load, function(value, ctx)
    if not live(s) or s.generation ~= generation then return end
    local current = s.model and draft(s)
    if s.model and not current then notify('Cannot refresh an invalid Issue draft'); return end
    if not s.model or not dirty(s) then s.baseline, current = vim.deepcopy(value.issue), nil end
    s.model, s.ctx = value, ctx
    vim.b[buf].git_issue_ctx = ctx
    require('git.buffer_names').assign(buf, require('git.buffer_names').uri('git-issue', ctx.root,
      ('%s/%s/issues/%d'):format(ctx.host, ctx.repo, ctx.number)))
    render(s, current)
  end, false, function(err)
    if not live(s) or s.generation ~= generation or s.model then return end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'Issue unavailable: ' .. tostring(err):gsub('[\r\n]', ' '), 'R retries · q closes' })
    vim.bo[buf].modified, vim.bo[buf].modifiable = false, false
  end)
end
function M.write(buf)
  local s = states[buf]
  if not s or not s.model or s.saving then return end
  local current, err = draft(s)
  if not current then notify(err); return end
  if vim.trim(current[1] or '') == '' or current[2] ~= '' then notify('Keep a title, a blank line, then the Issue body'); return end
  if vim.deep_equal(current, s.original) then vim.bo[buf].modified = false; return end
  local expected, body = vim.deepcopy(s.baseline), table.concat(vim.list_slice(current, 3), '\n')
  s.saving = true
  actions.run(vim.tbl_extend('force', s.ctx, { notify_change = false }), function(ctx)
    return model.write(ctx, expected, current[1], body)
  end, function(value, ctx)
    s.saving = false
    if live(s) then
      value.body = github.scalar(value.body) or ''
      local latest = draft(s)
      local merged = latest
      if latest and latest[2] == '' then
        -- Adopt the server value for fields unchanged during this request;
        -- preserve only edits actually made while the save was running.
        local latest_body = table.concat(vim.list_slice(latest, 3), '\n')
        merged = message({ title = latest[1] == current[1] and value.title or latest[1],
          body = latest_body == body and value.body or latest_body })
      end
      s.baseline, s.original = value, message(value)
      render(s, merged)
    end
    github.changed(ctx)
    vim.notify('Issue updated')
  end, true, function() s.saving = false end)
end
function M.comment(buf)
  local s = states[buf]
  if not s or not s.model then return end
  return require('git.features.pr_composer').open({ ctx = s.ctx, title = 'Issue comment', viewer = s.model.viewer,
    prefix = { ('%s #%d · %s'):format(s.ctx.repo, s.ctx.number, s.model.issue.title) },
    history = s.model.conversation.entries, submit = model.comment })
end
function M.lifecycle(buf)
  local s = states[buf]
  if not s or not s.model then return end
  local expected, ctx = vim.deepcopy(s.model.issue), vim.deepcopy(s.ctx)
  local function apply(reason)
    actions.run(ctx, function(target) return model.lifecycle(target, expected, reason) end,
      function() vim.notify(expected.state == 'open' and 'Issue closed' or 'Issue reopened') end, true)
  end
  if expected.state == 'closed' then return apply() end
  vim.ui.select({ { label = 'Close as completed', reason = 'completed' },
    { label = 'Close as not planned', reason = 'not_planned' } },
    { prompt = 'Close Issue #' .. ctx.number, format_item = function(item) return item.label end },
    function(item) if item then apply(item.reason) end end)
end
local function toggle(s, mode)
  local current, err = draft(s)
  if not current then notify(err); return end
  local row = vim.fn.line('.')
  local key = row >= s.conversation_row + offset(s) and 'conversation_expanded' or row <= #s.prefix and 'header_expanded'
  if not key then return end
  s[key] = mode == 'show' or (mode ~= 'hide' and not s[key])
  render(s, current)
end
function M.show_conversation(buf)
  local s = states[buf]
  if not s or not s.model then return end
  local current = draft(s)
  if not current then return end
  s.conversation_expanded = true; render(s, current)
  local win = vim.fn.bufwinid(buf)
  if win ~= -1 then vim.api.nvim_win_set_cursor(win, { s.first_item or s.conversation_row, 0 }) end
end
function M.action_groups(buf)
  local s, win = states[buf], vim.api.nvim_get_current_win()
  if not s or not s.model then return {} end
  local captured, row, tick = s.model, vim.api.nvim_win_get_cursor(win), vim.api.nvim_buf_get_changedtick(buf)
  local function run(fn)
    return function()
      if not live(s) or s.model ~= captured or vim.api.nvim_buf_get_changedtick(buf) ~= tick or not vim.api.nvim_win_is_valid(win)
        or vim.api.nvim_win_get_buf(win) ~= buf or not vim.deep_equal(vim.api.nvim_win_get_cursor(win), row) then
        vim.notify('Issue view changed; reopen the menu'); return
      end
      vim.api.nvim_set_current_win(win); fn()
    end
  end
  return { { title = 'Issue', actions = {
    { key = 'c', label = 'Write comment', run = run(function() M.comment(buf) end) },
    { key = 'p', label = 'Show conversation', run = run(function() M.show_conversation(buf) end) },
    { key = 'A', label = 'Comment reactions / edit / delete', run = run(function()
      local item = M.conversation_at(buf, row[1])
      if item then require('git.features.pr_comment_actions').menu(s.ctx, item, s.model.viewer)
      else vim.notify('Select a conversation comment') end
    end) },
    { key = 'e', label = 'Edit title / body', run = run(function() vim.api.nvim_win_set_cursor(win, { #s.prefix + 1, 0 }); vim.cmd('startinsert') end) },
    { key = 'M', label = 'Labels / assignees…', run = run(function() require('git.features.pr_metadata').menu(s.ctx) end) },
    { key = 'x', label = s.model.issue.state == 'closed' and 'Reopen Issue' or 'Close Issue…', run = run(function() M.lifecycle(buf) end) },
    { key = 'b', label = 'Open in browser', run = run(function() vim.ui.open(s.ctx.url) end) },
    { key = 'R', label = 'Refresh Issue', run = run(function() M.refresh(buf) end) },
  } } }
end
local function configure(win, active)
  local options = { number = false, relativenumber = false, wrap = false, foldenable = false, list = false,
    signcolumn = 'yes:1', statuscolumn = '%s', foldcolumn = '0' }
  if active then
    if not windows[win] then
      windows[win] = {}
      for name in pairs(vim.tbl_extend('force', options, { conceallevel = 0, concealcursor = '' })) do
        windows[win][name] = vim.api.nvim_get_option_value(name, { scope = 'local', win = win })
      end
    end
    for name, value in pairs(options) do vim.api.nvim_set_option_value(name, value, { scope = 'local', win = win }) end
  elseif windows[win] then
    local saved = windows[win]; windows[win] = nil
    for name, value in pairs(saved) do vim.api.nvim_set_option_value(name, value, { scope = 'local', win = win }) end
  end
end
local window_group = vim.api.nvim_create_augroup('GitIssueWindows', { clear = true })
vim.api.nvim_create_autocmd('BufWinEnter', { group = window_group, callback = function(ev) configure(vim.api.nvim_get_current_win(), states[ev.buf]) end })
vim.api.nvim_create_autocmd('WinClosed', { group = window_group, callback = function(ev) windows[tonumber(ev.match)] = nil end })
local function attach(s)
  local buf = s.buf
  s.edit_guard = require('git.features.pr_edit_guard').attach(s, function(current) render(s, current) end)
  local pending = false
  vim.api.nvim_buf_attach(buf, false, { on_lines = function()
    if not s.model or s.rendering or pending then return end
    pending = true
    vim.schedule(function() pending = false; if live(s) then paint(s) end end)
  end })
  for _, key in ipairs({ 'i', 'a', 'I', 'gI', '<Insert>', 's', 'S', 'C', 'c', 'x', 'X', 'r', 'p', 'P', 'gP', '~', 'g~' }) do
    vim.keymap.set('n', key, function() return editable(s, vim.fn.line('.')) and key or '' end,
      { buffer = buf, expr = true, silent = true, desc = 'Edit only Issue title / body' })
  end
  for _, key in ipairs({ 'c', 's', 'S', 'C', 'd', 'x', 'X', 'p', 'P', 'r', '~' }) do
    vim.keymap.set('x', key, function()
      return editable(s, vim.fn.line('v')) and editable(s, vim.fn.line('.')) and key or '<Esc>'
    end, { buffer = buf, expr = true, silent = true })
  end
  local function map(key, fn, desc, native)
    vim.keymap.set('n', key, function()
      if native and editable(s, vim.fn.line('.')) then vim.cmd.normal({ key, bang = true }); return end
      if s.model then fn() end
    end, { buffer = buf, silent = true, desc = desc })
  end
  for key, mode in pairs({ o = 'toggle', ['='] = 'toggle', ['<Tab>'] = 'toggle', ['>'] = 'show', ['<'] = 'hide' }) do
    map(key, function() toggle(s, mode) end, 'Toggle / expand / collapse Issue section', true)
  end
  for _, key in ipairs({ 'gc', 'gC', 'gcn', 'gcp' }) do map(key, function() M.comment(buf) end, 'Write Issue comment / read history') end
  map('gA', function()
    local item = M.conversation_at(buf, vim.fn.line('.'))
    if item then require('git.features.pr_comment_actions').menu(s.ctx, item, s.model.viewer) else vim.notify('Select a conversation comment') end
  end, 'Comment reactions / edit / delete')
  map('gE', function()
    local field = s.metadata_rows[vim.fn.line('.')]
    if field then require('git.features.pr_metadata').choose(s.ctx, field) else require('git.features.pr_metadata').menu(s.ctx) end
  end, 'Change Issue labels / assignees')
  map('gco', function() M.show_conversation(buf) end, 'Show Issue conversation')
  map('gh', function() vim.api.nvim_win_set_cursor(0, { 1, 0 }) end, 'Go to Issue header')
  map('cw', function() vim.api.nvim_win_set_cursor(0, { #s.prefix + 1, 0 }); vim.cmd('startinsert') end, 'Edit Issue title / body', true)
  map('A', function() vim.api.nvim_win_set_cursor(0, { #s.prefix + 1, 0 }); vim.cmd('startinsert') end, 'Edit Issue title / body', true)
  map('gx', function()
    local item = M.conversation_at(buf, vim.fn.line('.')); vim.ui.open(item and item.url or s.ctx.url)
  end, 'Open Issue / comment in browser')
  map('gy', function() vim.fn.setreg('"', s.ctx.url); pcall(vim.fn.setreg, '+', s.ctx.url) end, 'Copy Issue URL')
  map('<CR>', function()
    local row, item = vim.fn.line('.'), M.conversation_at(buf, vim.fn.line('.'))
    if row == 1 or row == s.conversation_row + offset(s) then toggle(s, 'toggle')
    elseif item and require('git.features.pr_timeline').is_event(item) then vim.ui.open(item.url)
    elseif item then M.comment(buf)
    elseif s.metadata_rows[row] then require('git.features.pr_metadata').choose(s.ctx, s.metadata_rows[row]) end
  end, 'Toggle Issue section / open conversation')
  vim.keymap.set('n', 'R', function()
    if editable(s, vim.fn.line('.')) then vim.cmd.normal({ 'R', bang = true }) else M.refresh(buf) end
  end, { buffer = buf, silent = true, desc = 'Refresh Issue, preserving draft' })
  vim.keymap.set('n', 'q', function()
    require('utilities').smart_close({ force = true, before = function()
      if s.saving then vim.notify('An Issue save is running; wait for its result'); return false end
      if dirty(s) and vim.fn.confirm('Discard unsaved Issue title/body?', '&Discard\n&Keep', 2) ~= 1 then return false end
    end })
  end, { buffer = buf, silent = true, desc = 'Close Issue' })
  actions.attach(buf)
  vim.keymap.set('n', '<Space><Space>', function() actions.open(actions.context(buf)) end, { buffer = buf, silent = true, desc = 'Issue action menu' })
  map('?', function() require('git.features.help').show_text('Issue keys', {
    'cw / A  Edit title / body     <C-s> / :w  Save',
    'o / Tab / = / > / <  Fold / expand sections',
    'gc / gC / gcn / gcp  Comment composer + history',
    'gA  Comment reactions / edit / delete     gE  Labels / assignees',
    'gco  Show conversation     gh  Header     gx / gy  Browser / copy URL',
    'N / <Space><Space>  Issue actions, including close / reopen',
    'R  Refresh outside draft     q  Close',
  }) end, 'Issue key guide')
  local group = vim.api.nvim_create_augroup('GitIssue' .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ 'InsertEnter', 'CursorMovedI' }, { group = group, buffer = buf,
    callback = function() if not editable(s, vim.fn.line('.')) then vim.cmd('stopinsert') end end })
  vim.api.nvim_create_autocmd('BufWriteCmd', { group = group, buffer = buf, callback = function(ev)
    if ev.match ~= vim.api.nvim_buf_get_name(buf) then error('Use :w without a filename to save the Issue') end
    M.write(buf)
  end })
  vim.keymap.set({ 'n', 'i' }, '<C-s>', function() vim.cmd('write') end, { buffer = buf, silent = true })
  vim.api.nvim_create_autocmd('User', { group = group, pattern = 'GitHubChanged', callback = function(ev)
    local ctx = ev.data or {}
    if s.model and ctx.resource_kind == 'issue' and ctx.host == s.ctx.host and ctx.repo == s.ctx.repo
      and (not ctx.number or ctx.number == s.ctx.number) then M.refresh(buf) end
  end })
  vim.api.nvim_create_autocmd('BufWipeout', { group = group, buffer = buf, once = true, callback = function()
    states[buf] = nil
    if s.task then s.task.cancel() end
    pcall(vim.api.nvim_del_augroup_by_id, group)
  end })
end
function M.open(opts)
  opts = vim.deepcopy(opts or {})
  opts.root = utils.normalize_path(opts.root or utils.get_buf_work_tree(vim.api.nvim_get_current_buf()) or utils.get_work_tree({}))
  if not opts.root then notify('Not in a Git repository'); return end
  opts.resource_kind = 'issue'
  local requested = github.issue_url_context(opts.url)
  if opts.url and not requested then notify('Use an Issue URL, not a pull request URL'); return end
  if not opts.number and not requested then return require('git.features.issue_actions').list(opts) end
  if requested then opts = vim.tbl_extend('force', opts, requested) end
  local identity = table.concat({ opts.root, opts.host or '', opts.repo or '', tostring(opts.number) }, '/')
  for buf, s in pairs(states) do
    if live(s) and s.ctx.root == opts.root and (s.identity == identity or (opts.host == s.ctx.host and opts.repo == s.ctx.repo and opts.number == s.ctx.number)) then
      local win = vim.fn.bufwinid(buf)
      if win ~= -1 then vim.api.nvim_set_current_win(win) else utils.open_panel_split(); vim.api.nvim_win_set_buf(0, buf) end
      if not s.model then M.refresh(buf) end
      return buf
    end
  end
  local buf = vim.api.nvim_create_buf(true, false)
  local s = { buf = buf, ctx = opts, identity = identity, header_expanded = true, conversation_expanded = true }
  states[buf] = s
  require('git.buffer_names').assign(buf, require('git.buffer_names').uri('git-issue', opts.root,
    ('%s/%s/issues/%s'):format(opts.host or 'remote', opts.repo or 'repository', opts.number)))
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile, vim.bo[buf].undofile = 'acwrite', 'hide', false, false
  utils.set_buf_work_tree(buf, opts.root)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'Loading Issue…' })
  vim.bo[buf].modified, vim.bo[buf].modifiable = false, false
  utils.open_panel_split(); vim.api.nvim_win_set_buf(0, buf)
  markdown.prepare(buf)
  vim.bo[buf].filetype = 'gitissue'
  configure(vim.api.nvim_get_current_win(), true)
  attach(s); M.refresh(buf)
  return buf
end
function M.setup()
  local options = require('git.features.issue_options')
  vim.api.nvim_create_user_command('GitIssue', function(args)
    local ok, filters, selector = pcall(options.parse, args.args, true)
    if not ok then notify(filters); return end
    local opts = actions.context()
    opts.number, opts.url = nil, nil
    if selector then
      if github.issue_url_context(selector) then opts.url = selector
      elseif tonumber(selector) then opts.number = tonumber(selector)
      else notify('Use :GitIssue [Issue number|URL] or [--state open|closed|all --limit N --label LABEL --assignee USER]'); return end
      M.open(opts)
    else require('git.features.issue_actions').list(opts, filters) end
  end, { nargs = '*', complete = options.complete, desc = 'Open native Issue (or filtered, limited Issue list)' })
  vim.api.nvim_create_user_command('GitIssueList', function(args)
    local ok, filters = pcall(options.parse, args.args, false)
    if not ok then notify(filters); return end
    require('git.features.issue_actions').list(actions.context(), filters)
  end, { nargs = '*', complete = options.complete, desc = 'List Issues with state, limit, label and assignee filters' })
  vim.api.nvim_create_user_command('GitIssueCreate', function() require('git.features.issue_actions').create(actions.context()) end, {})
end
return M
