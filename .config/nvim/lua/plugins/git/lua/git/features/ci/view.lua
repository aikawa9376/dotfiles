-- PR result -> normal detail tab -> searchable log splits. No polling/popups.
local M = {}
local async = require('git.features.async')
local model = require('git.features.ci.model')
local transport = require('git.features.ci.transport')
local service = require('git.features.ci.service')
local locations = require('git.features.ci.log_locations')
local utils = require('git.utils')
local states, by_key = {}, {}
-- Only tabs created by gf are reusable source destinations. User windows found
-- by exact target identity are focused, but never repurposed for another file.
local source_windows = {}
local ns = vim.api.nvim_create_namespace('git_ci_details')
for group, link in pairs({ GitCiTitle = 'Title', GitCiHeading = 'Title', GitCiFailedStep = 'DiagnosticError', GitCiLink = 'Underlined' }) do
  vim.api.nvim_set_hl(0, group, { default = true, link = link })
end
local names = { github_actions = 'GitHub Actions', circleci = 'CircleCI', generic = 'Other CI' }
local function one(value) return (transport.clean(value):gsub('\n', ' ')) end
local function write(buf, lines)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  vim.bo[buf].readonly, vim.bo[buf].modifiable = false, true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified, vim.bo[buf].modifiable, vim.bo[buf].readonly = false, false, true
end
local function source(s)
  if vim.api.nvim_tabpage_is_valid(s.source_tab) then vim.api.nvim_set_current_tabpage(s.source_tab) end
  if vim.api.nvim_win_is_valid(s.source_win) and vim.api.nvim_win_get_buf(s.source_win) == s.source_buf then
    vim.api.nvim_set_current_win(s.source_win)
    local row = math.min(s.source_cursor[1], vim.api.nvim_buf_line_count(s.source_buf))
    local line = vim.api.nvim_buf_get_lines(s.source_buf, row - 1, row, false)[1] or ''
    vim.api.nvim_win_set_cursor(s.source_win, { row, math.min(s.source_cursor[2], #line) })
  end
end
local function alive(s)
  return not s.closed and vim.api.nvim_buf_is_valid(s.buf) and vim.api.nvim_win_is_valid(s.win) and vim.api.nvim_win_get_buf(s.win) == s.buf
end
local function stop(s)
  s.closed = true
  if by_key[s.key] == s then by_key[s.key] = nil end
  if s.task then s.task.cancel() end
  for _, log in pairs(s.logs) do if log.task then log.task.cancel() end end
end
local function close(s)
  if not vim.api.nvim_tabpage_is_valid(s.tab) then stop(s); source(s); return end
  local owned = { [s.win] = s.buf }
  for _, log in pairs(s.logs) do owned[log.win] = log.buf end
  local wins = vim.api.nvim_tabpage_list_wins(s.tab)
  local all_owned = true
  for _, win in ipairs(wins) do if owned[win] ~= vim.api.nvim_win_get_buf(win) then all_owned = false end end
  stop(s)
  if all_owned and #vim.api.nvim_list_tabpages() > 1 then
    vim.api.nvim_set_current_tabpage(s.tab); vim.cmd('tabclose')
  else
    for _, win in ipairs(wins) do if owned[win] == vim.api.nvim_win_get_buf(win) then pcall(vim.api.nvim_win_close, win, false) end end
  end
  source(s)
end
local function scratch(ctx, name, filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  local names = require('git.buffer_names')
  names.assign(buf, names.uri('git-ci', ctx.root, name))
  vim.bo[buf].buftype, vim.bo[buf].bufhidden = 'nofile', 'wipe'
  vim.bo[buf].swapfile, vim.bo[buf].undofile = false, false
  vim.bo[buf].filetype = filetype
  utils.set_buf_work_tree(buf, ctx.root)
  return buf
end
local function bind(buf, action, default, fn, description)
  local mappings = transport.config().keys or {}
  local key = mappings[action]
  if key == nil then key = default end
  if key == false then return end
  vim.keymap.set('n', key, fn, { buffer = buf, silent = true, nowait = true, desc = description })
end
local function render(s, focus_failure)
  if not alive(s) then return end
  local details, check = s.details or { check = s.check, steps = {}, annotations = {} }, s.details and s.details.check or s.check
  local cursor = vim.api.nvim_win_get_cursor(s.win)
  local old_step = s.rows and s.rows[cursor[1]]
  local icon, group = model.symbol(check.state)
  local lines, marks = {}, {}
  local function row(chunks)
    local line, at = '', #lines + 1
    for _, chunk in ipairs(chunks) do
      local value = one(chunk[1])
      if chunk[2] and value ~= '' then marks[#marks + 1] = { row = at, start = #line, finish = #line + #value, group = chunk[2] } end
      line = line .. value
    end
    lines[at] = line
    return at
  end
  local function detail(label, value, hl)
    row({ { label, 'GitPrHeaderLabel' }, { ': ', 'Normal' }, { value, hl or 'Normal' } })
  end
  local function hints(entries)
    local chunks = {}
    local mappings = transport.config().keys or {}
    for _, entry in ipairs(entries) do
      local key = mappings[entry[1]]
      if key == nil then key = entry[2] end
      if key ~= false then
        if #chunks > 0 then chunks[#chunks + 1] = { ' · ', 'Comment' } end
        local label = type(key) == 'table' and table.concat(key, ' / ') or key
        chunks[#chunks + 1] = { label:gsub('<CR>', 'Enter'), 'GitActionMenuKey' }
        chunks[#chunks + 1] = { ' ' .. entry[3], 'Comment' }
      end
    end
    return chunks
  end
  row({ { ('PR #%d'):format(check.pr_number), 'GitCiTitle' }, { ' / ', 'Comment' }, { check.name, 'GitCiTitle' },
    { ' · ', 'Comment' }, { icon .. ' ' .. one(check.state), group } })
  row({ { 'Provider', 'GitPrHeaderLabel' }, { ': ', 'Normal' }, { names[check.provider] or check.provider, 'Identifier' },
    { ' · ', 'Comment' }, { 'Duration', 'GitPrHeaderLabel' }, { ': ', 'Normal' },
    { model.duration(details.started_at or check.started_at, details.completed_at or check.completed_at), 'Number' } })
  detail('Commit', check.head_sha, 'Constant')
  if details.workflow then detail('Workflow', details.workflow, 'Identifier') end
  if details.attempt then detail('Run attempt', details.attempt, 'Number') end
  if check.url then detail('URL', check.url, 'GitCiLink') end
  lines[#lines + 1] = ''
  if s.loading then row({ { 'Loading check details…', 'DiagnosticInfo' } })
  elseif details.message then row({ { details.message, 'DiagnosticWarn' } }) end
  local description = details.description or check.description
  if description then row({ { description, 'GitCiHeading' } }) end
  if details.summary then vim.list_extend(lines, vim.split(transport.clean(details.summary), '\n', { plain = true })) end
  local rows, failure, selected = {}, nil, nil
  if #details.steps > 0 then
    lines[#lines + 1] = ''
    local heading = { { 'Steps', 'GitCiHeading' }, { ' · ', 'Comment' } }
    vim.list_extend(heading, hints({ { 'vertical', '<CR>', 'log' }, { 'horizontal', 's', 'horizontal log' } }))
    row(heading)
    for _, step in ipairs(details.steps) do
      local glyph, hl = model.symbol(step.state)
      local failed = model.bucket(step.state) == 'fail'
      local chunks = { { glyph .. ' ', hl }, { tostring(step.number or '—') .. '. ', 'Comment' },
        { step.name, failed and 'GitCiFailedStep' or step.log_available and 'Normal' or 'Comment' },
        { ' · ', 'Comment' }, { step.state, hl }, { ' · ', 'Comment' },
        { model.duration(step.started_at, step.completed_at), 'Comment' } }
      if not step.log_available then chunks[#chunks + 1] = { ' · log unavailable', 'Comment' } end
      local at = row(chunks)
      rows[at] = step
      if failed then failure = failure or at end
      if old_step and old_step.id == step.id then selected = at end
    end
  end
  if #details.annotations > 0 then
    lines[#lines + 1] = ''
    row({ { 'Annotations', 'GitCiHeading' } })
    for _, annotation in ipairs(details.annotations) do
      local hl = ({ failure = 'DiagnosticError', warning = 'DiagnosticWarn', notice = 'DiagnosticInfo' })[annotation.annotation_level] or 'Comment'
      row({ { annotation.path, 'Directory' }, { ':', 'Comment' }, { annotation.start_line, 'Number' },
        { ' · ', 'Comment' }, { annotation.annotation_level, hl } })
      vim.list_extend(lines, vim.split(transport.clean(annotation.message), '\n', { plain = true }))
    end
  end
  if details.annotation_error then row({ { 'Annotations: ', 'GitPrHeaderLabel' }, { details.annotation_error, 'DiagnosticWarn' } }) end
  lines[#lines + 1] = ''
  row(hints({ { 'refresh', 'R', 'refresh' }, { 'actions', 'a', 'workflow actions' }, { 'browser', 'o', 'web' }, { 'close', 'q', 'close' } }))
  s.rows = rows
  write(s.buf, lines)
  vim.api.nvim_buf_clear_namespace(s.buf, ns, 0, -1)
  for _, mark in ipairs(marks) do vim.api.nvim_buf_set_extmark(s.buf, ns, mark.row - 1, mark.start,
    { end_col = mark.finish, hl_group = mark.group, priority = 200 }) end
  vim.api.nvim_win_set_cursor(s.win, { focus_failure and (failure or 1) or selected or math.min(cursor[1], #lines), 0 })
end
local function log_key(s, step)
  return table.concat({ s.ctx.host, s.check.repo, s.check.head_sha, s.check.provider, step.id, tostring(s.generation) }, '/')
end
local function log_hints()
  local hints, keys = {}, transport.config().keys or {}
  for _, entry in ipairs({ { 'source', 'gf', 'source' }, { 'refresh', 'R', 'retry' }, { 'close', 'q', 'closes this log window' } }) do
    local key = keys[entry[1]]
    if key == nil then key = entry[2] end
    if key ~= false then
      hints[#hints + 1] = (type(key) == 'table' and table.concat(key, ' / ') or key):gsub('<CR>', 'Enter') .. ' ' .. entry[3]
    end
  end
  return table.concat(hints, ' · ')
end
local function log_write(log, result, err)
  local body = result and vim.split(result.text, '\n', { plain = true }) or {}
  local target = result and 1
  local lines = { result and result.scope or 'Log unavailable',
    (result and result.job_wide and 'Selected step: ' or '') .. one(log.step.name), '' }
  local body_start = #lines + 1
  if err then lines[#lines + 1] = one(err)
  else
    vim.list_extend(lines, body)
    if result.truncated then lines[#lines + 1] = ('[Log truncated at %d bytes]'):format(transport.limit()) end
  end
  log.locations = {}
  for row, loc in pairs(locations.index(body)) do log.locations[body_start + row - 1] = loc end
  lines[#lines + 1] = log_hints()
  write(log.buf, lines)
  vim.api.nvim_buf_clear_namespace(log.buf, ns, 0, -1)
  vim.api.nvim_buf_set_extmark(log.buf, ns, 0, 0, { end_col = #lines[1], hl_group = 'GitCiHeading' })
  if target and vim.api.nvim_win_is_valid(log.win) and vim.api.nvim_win_get_buf(log.win) == log.buf then
    vim.api.nvim_win_set_cursor(log.win, { body_start + target - 1, 0 })
    -- Scroll this window without taking focus from another log/detail window.
    vim.api.nvim_win_call(log.win, function() vim.cmd('normal! zt') end)
  end
end
local function fetch_log(s, log, refresh)
  if not alive(s) or not vim.api.nvim_win_is_valid(log.win) or vim.api.nvim_win_get_buf(log.win) ~= log.buf then return end
  if log.stale then write(log.buf, { 'Outdated log: refresh details, then open the step again.' }); return end
  if log.task then log.task.cancel() end
  log.locations = {}
  if refresh then s.cache[log.key] = nil end
  local cached = s.cache[log.key]
  if cached then log_write(log, cached); return end
  local generation = s.generation
  write(log.buf, { 'Loading step log…', one(log.step.name) })
  log.task = async.run(s.ctx.root, function() return service.log(s.ctx, s.details.check, log.step) end, function(ok, result)
    if not alive(s) or generation ~= s.generation or log.stale or not vim.api.nvim_win_is_valid(log.win)
      or vim.api.nvim_win_get_buf(log.win) ~= log.buf then return end
    if ok then s.cache[log.key] = result; log_write(log, result) else log_write(log, nil, result) end
  end)
end
local function ordinary_window(win)
  for _, name in ipairs({ 'number', 'relativenumber', 'numberwidth', 'wrap', 'linebreak', 'breakindent',
    'foldmethod', 'foldenable', 'foldcolumn', 'foldtext', 'signcolumn', 'statuscolumn',
    'list', 'listchars', 'fillchars', 'winhighlight', 'cursorline', 'cursorcolumn',
    'colorcolumn', 'conceallevel', 'concealcursor', 'spell', 'scrolloff', 'sidescrolloff' }) do
    vim.api.nvim_set_option_value(name, vim.api.nvim_get_option_value(name, { scope = 'global' }), { win = win, scope = 'local' })
  end
end
local function open_source(s, log)
  if log.stale then return end
  local loc = (log.locations or {})[vim.api.nvim_win_get_cursor(0)[1]]
  if not loc then vim.notify('No unambiguous source location in this log block', vim.log.levels.INFO); return end
  local abs, path = locations.relative(s.ctx.root, loc.path)
  if not abs then vim.notify('Source location is outside the repository', vim.log.levels.INFO); return end
  local objects = require('git.objects')
  local name, object = abs
  local remote_ok, remote = pcall(require('git.features.pr_model').remote, s.ctx)
  local local_repo = remote_ok and not remote:find('://', 1, true)
  if not local_repo or vim.fn.filereadable(abs) ~= 1 then
    -- PR objects are fetched into the caller's repository even for foreign PRs.
    -- An unrelated worktree may contain the same filename. Only a matching
    -- configured repository uses editable local files; otherwise pin the SHA.
    -- Resolve without fetching or checking out a branch.
    local sha = s.check.head_sha
    if type(sha) == 'string' and sha:match('^%x+$') and #sha >= 40 then
      object = sha .. ':' .. path
      local ok, kind = pcall(objects.run, s.ctx.root, { 'cat-file', '-t', object })
      if not ok or vim.trim(kind) ~= 'blob' then object = nil end
    end
    if not object then vim.notify('Source file unavailable in the worktree or captured CI commit: ' .. path, vim.log.levels.INFO); return end
    name = objects.uri(s.ctx.root, object)
  end
  local return_win, prior_target = vim.api.nvim_get_current_win(), vim.fn.bufnr(name)
  local destination, previous_buf, created
  local ok, err = pcall(function()
    local existing
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)) == name then existing = win; break end
    end
    if existing then vim.api.nvim_set_current_win(existing)
    else
      destination = source_windows[s.ctx.root]
      if destination and vim.api.nvim_win_is_valid(destination.win)
        and vim.api.nvim_win_get_buf(destination.win) == destination.buf then
        vim.api.nvim_set_current_win(destination.win)
      else
        vim.cmd('tabnew')
        destination = { win = vim.api.nvim_get_current_win() }
        source_windows[s.ctx.root] = destination
        created = true
      end
      previous_buf = vim.api.nvim_get_current_buf()
      ordinary_window(destination.win)
      -- Hide explicitly: keep unsaved text even when the user's hidden is off.
      if object then objects.open(object, 'hide edit', s.ctx.root)
      else vim.cmd('hide edit ' .. vim.fn.fnameescape(abs)) end
      destination.buf = vim.api.nvim_get_current_buf()
      -- PR-window restoration / Git-object handlers may apply panel settings
      -- on entry. Source navigation always restores ordinary editing defaults.
      ordinary_window(destination.win)
    end
    local row = math.min(loc.row, vim.api.nvim_buf_line_count(0))
    local line = vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1] or ''
    vim.api.nvim_win_set_cursor(0, { row, math.min(loc.col - 1, #line) })
    vim.cmd('normal! zz')
  end)
  if not ok then
    if created then
      if vim.api.nvim_win_is_valid(destination.win) then pcall(vim.api.nvim_win_close, destination.win, true) end
      source_windows[s.ctx.root] = nil
    elseif destination and previous_buf and vim.api.nvim_win_is_valid(destination.win) and vim.api.nvim_buf_is_valid(previous_buf) then
      pcall(vim.api.nvim_win_set_buf, destination.win, previous_buf)
      destination.buf = previous_buf
    end
    local failed = vim.fn.bufnr(name)
    if prior_target == -1 and failed ~= -1 and not vim.bo[failed].modified then pcall(vim.api.nvim_buf_delete, failed, {}) end
    if vim.api.nvim_win_is_valid(return_win) then vim.api.nvim_set_current_win(return_win) end
    vim.notify(tostring(err), vim.log.levels.WARN)
  end
end
local function open_log(s, vertical)
  if not alive(s) or s.loading then return end
  local step = s.rows[vim.api.nvim_win_get_cursor(s.win)[1]]
  if not step then vim.notify('Select a step to open its log', vim.log.levels.INFO); return end
  if not step.log_available then vim.notify(step.log_reason or 'Native log unavailable; o opens the web view.', vim.log.levels.INFO); return end
  local key = log_key(s, step)
  local previous = s.logs[key]
  if previous and vim.api.nvim_win_is_valid(previous.win) and vim.api.nvim_win_get_buf(previous.win) == previous.buf then
    vim.api.nvim_set_current_win(previous.win); return
  end
  vim.api.nvim_set_current_win(s.win)
  vim.cmd(vertical and 'botright vsplit' or 'botright split')
  local win = vim.api.nvim_get_current_win()
  local buf = scratch(s.ctx, s.check.id .. '/log/' .. tostring(step.id or step.name), 'log')
  local log = { buf = buf, win = win, key = key, step = step }
  s.logs[key] = log
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_set_option_value('wrap', false, { win = win, scope = 'local' })
  local function log_close()
    local current = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_buf(current) == buf then pcall(vim.api.nvim_win_close, current, false) end
    if alive(s) then vim.api.nvim_set_current_win(s.win) end
  end
  bind(buf, 'close', 'q', log_close, 'Close this CI log window')
  bind(buf, 'refresh', 'R', function() fetch_log(s, log, true) end, 'Retry selected step log')
  bind(buf, 'source', 'gf', function() open_source(s, log) end, 'Open source location from this CI log block')
  vim.api.nvim_create_autocmd('WinClosed', { group = s.group, pattern = tostring(win), once = true, callback = function()
    if log.task then log.task.cancel() end
  end })
  fetch_log(s, log)
end
local function refresh(s)
  if not alive(s) then return end
  if s.task then s.task.cancel() end
  s.generation = s.generation + 1; s.cache = {}
  for _, log in pairs(s.logs) do
    log.stale = true
    if log.task then log.task.cancel() end
    write(log.buf, { 'Outdated log: details were refreshed. Open the step again for current output.' })
  end
  local generation = s.generation
  s.loading, s.details = true, nil; render(s)
  s.task = async.run(s.ctx.root, function() return service.details(s.ctx, s.check) end, function(ok, details)
    if not alive(s) or generation ~= s.generation then return end
    s.loading = false
    s.details = ok and details or { check = s.check, steps = {}, annotations = {}, message = details }
    render(s, true)
  end)
end
function M.open(ctx, check)
  local key = ctx.root .. '/' .. check.id
  local previous = by_key[key]
  if previous and alive(previous) then
    vim.api.nvim_set_current_win(previous.win)
    if not vim.deep_equal(previous.check, check) then
      previous.check, previous.ctx = vim.deepcopy(check), vim.deepcopy(ctx)
      refresh(previous)
    end
    return previous.buf
  end
  local source_win = vim.api.nvim_get_current_win()
  local s = { ctx = vim.deepcopy(ctx), check = vim.deepcopy(check), key = key, generation = 0, logs = {}, cache = {},
    source_tab = vim.api.nvim_get_current_tabpage(), source_win = source_win,
    source_buf = vim.api.nvim_win_get_buf(source_win), source_cursor = vim.api.nvim_win_get_cursor(source_win) }
  vim.cmd('tabnew')
  s.tab, s.win = vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win()
  local empty = vim.api.nvim_get_current_buf()
  s.buf = scratch(ctx, check.id .. '/check', 'gitcicheck')
  vim.api.nvim_win_set_buf(s.win, s.buf)
  if vim.api.nvim_buf_is_valid(empty) and vim.api.nvim_buf_get_name(empty) == '' and not vim.bo[empty].modified then pcall(vim.api.nvim_buf_delete, empty, {}) end
  for name, value in pairs({ wrap = false, number = false, relativenumber = false }) do
    vim.api.nvim_set_option_value(name, value, { win = s.win, scope = 'local' })
  end
  states[s.buf], by_key[key] = s, s
  s.group = vim.api.nvim_create_augroup('GitCi' .. s.buf, { clear = true })
  bind(s.buf, 'horizontal', 's', function() open_log(s, false) end, 'Open selected step log in horizontal split')
  bind(s.buf, 'vertical', '<CR>', function() open_log(s, true) end, 'Open selected step log in vertical split')
  bind(s.buf, 'refresh', 'R', function() refresh(s) end, 'Refresh CI check details and invalidate logs')
  bind(s.buf, 'actions', 'a', function()
    require('git.features.ci.actions').menu(s.ctx, s.details and s.details.check or s.check, function() refresh(s) end)
  end, 'Rerun / cancel CI workflow')
  bind(s.buf, 'close', 'q', function() close(s) end, 'Close owned CI windows and return to PR')
  local function browse()
    local url = s.details and s.details.check.url or s.check.url
    if url then vim.ui.open(url) else vim.notify('This check has no safe web URL', vim.log.levels.INFO) end
  end
  bind(s.buf, 'browser', 'o', browse, 'Open CI check on the web')
  vim.keymap.set('n', 'gx', browse, { buffer = s.buf, silent = true, desc = 'Open CI check on the web' })
  vim.api.nvim_create_autocmd('WinClosed', { group = s.group, pattern = tostring(s.win), once = true, callback = function() stop(s) end })
  vim.api.nvim_create_autocmd('BufWipeout', { group = s.group, buffer = s.buf, once = true, callback = function()
    stop(s); states[s.buf] = nil; pcall(vim.api.nvim_del_augroup_by_id, s.group)
  end })
  refresh(s)
  return s.buf
end
function M.step_at(buf, row) local s = states[buf]; return s and s.rows and s.rows[row] end
function M.details(buf) local s = states[buf]; return s and not s.loading and s.details or nil end
return M
