-- PR result -> normal detail tab -> searchable log splits. No polling/popups.
local M = {}
local async = require('git.features.async')
local model = require('git.features.ci.model')
local transport = require('git.features.ci.transport')
local service = require('git.features.ci.service')
local utils = require('git.utils')
local states, by_key = {}, {}
local ns = vim.api.nvim_create_namespace('git_ci_details')
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
  vim.api.nvim_buf_set_name(buf, 'git-ci://' .. buf .. '/' .. name)
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
  local lines = { ('PR #%d / %s · %s %s'):format(check.pr_number, one(check.name), icon, one(check.state)),
    ('Provider: %s · Duration: %s'):format(names[check.provider] or check.provider,
      model.duration(details.started_at or check.started_at, details.completed_at or check.completed_at)),
    'Commit: ' .. check.head_sha }
  if details.workflow then lines[#lines + 1] = 'Workflow: ' .. one(details.workflow) end
  if details.attempt then lines[#lines + 1] = 'Run attempt: ' .. one(details.attempt) end
  if check.url then lines[#lines + 1] = 'URL: ' .. check.url end
  lines[#lines + 1] = ''
  if s.loading then lines[#lines + 1] = 'Loading check details…'
  elseif details.message then lines[#lines + 1] = one(details.message) end
  local description = details.description or check.description
  if description then lines[#lines + 1] = one(description) end
  if details.summary then vim.list_extend(lines, vim.split(transport.clean(details.summary), '\n', { plain = true })) end
  local rows, failure, selected, marks = {}, nil, nil, {}
  if #details.steps > 0 then
    vim.list_extend(lines, { '', 'Steps · s horizontal log · v vertical log' })
    for _, step in ipairs(details.steps) do
      local glyph, hl = model.symbol(step.state)
      lines[#lines + 1] = ('%s %s. %s · %s · %s%s'):format(glyph, step.number or '—', one(step.name), one(step.state),
        model.duration(step.started_at, step.completed_at), step.log_available and '' or ' · log unavailable')
      rows[#lines] = step
      marks[#marks + 1] = { row = #lines, group = hl }
      if model.bucket(step.state) == 'fail' then failure = failure or #lines end
      if old_step and old_step.id == step.id then selected = #lines end
    end
  end
  if #details.annotations > 0 then
    vim.list_extend(lines, { '', 'Annotations' })
    for _, annotation in ipairs(details.annotations) do
      lines[#lines + 1] = ('%s:%s · %s'):format(one(annotation.path), one(annotation.start_line), one(annotation.annotation_level))
      vim.list_extend(lines, vim.split(transport.clean(annotation.message), '\n', { plain = true }))
    end
  end
  if details.annotation_error then lines[#lines + 1] = 'Annotations: ' .. one(details.annotation_error) end
  vim.list_extend(lines, { '', 'R refresh · o / gx web · q close' })
  s.rows = rows
  write(s.buf, lines)
  vim.api.nvim_buf_clear_namespace(s.buf, ns, 0, -1)
  vim.api.nvim_buf_set_extmark(s.buf, ns, 0, 0, { end_col = #lines[1], hl_group = group })
  for _, mark in ipairs(marks) do vim.api.nvim_buf_set_extmark(s.buf, ns, mark.row - 1, 0, { end_col = #lines[mark.row], hl_group = mark.group }) end
  vim.api.nvim_win_set_cursor(s.win, { focus_failure and (failure or 1) or selected or math.min(cursor[1], #lines), 0 })
end
local function log_key(s, step)
  return table.concat({ s.ctx.host, s.check.repo, s.check.head_sha, s.check.provider, step.id, tostring(s.generation) }, '/')
end
local function log_write(log, result, err)
  local lines = { result and result.scope or 'Log unavailable', one(log.step.name), '' }
  if err then lines[#lines + 1] = one(err)
  else
    vim.list_extend(lines, vim.split(result.text, '\n', { plain = true }))
    if result.truncated then lines[#lines + 1] = ('[Log truncated at %d bytes]'):format(transport.limit()) end
  end
  lines[#lines + 1] = 'R retry · q closes this log window'
  write(log.buf, lines)
end
local function fetch_log(s, log, refresh)
  if not alive(s) or not vim.api.nvim_win_is_valid(log.win) or vim.api.nvim_win_get_buf(log.win) ~= log.buf then return end
  if log.stale then write(log.buf, { 'Outdated log: refresh details, then open the step again.' }); return end
  if log.task then log.task.cancel() end
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
  local buf = scratch(s.ctx, 'log', 'log')
  local log = { buf = buf, win = win, key = key, step = step }
  s.logs[key] = log
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].wrap = false
  local function log_close()
    local current = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_buf(current) == buf then pcall(vim.api.nvim_win_close, current, false) end
    if alive(s) then vim.api.nvim_set_current_win(s.win) end
  end
  bind(buf, 'close', 'q', log_close, 'Close this CI log window')
  bind(buf, 'refresh', 'R', function() fetch_log(s, log, true) end, 'Retry selected step log')
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
  s.buf = scratch(ctx, 'PR-' .. check.pr_number .. '-check', 'gitcicheck')
  vim.api.nvim_win_set_buf(s.win, s.buf)
  if vim.api.nvim_buf_is_valid(empty) and vim.api.nvim_buf_get_name(empty) == '' and not vim.bo[empty].modified then pcall(vim.api.nvim_buf_delete, empty, {}) end
  vim.wo[s.win].wrap, vim.wo[s.win].number, vim.wo[s.win].relativenumber = false, false, false
  states[s.buf], by_key[key] = s, s
  s.group = vim.api.nvim_create_augroup('GitCi' .. s.buf, { clear = true })
  bind(s.buf, 'horizontal', 's', function() open_log(s, false) end, 'Open selected step log in horizontal split')
  bind(s.buf, 'vertical', 'v', function() open_log(s, true) end, 'Open selected step log in vertical split')
  bind(s.buf, 'refresh', 'R', function() refresh(s) end, 'Refresh CI check details and invalidate logs')
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
