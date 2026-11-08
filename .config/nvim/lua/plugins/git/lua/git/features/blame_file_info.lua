-- File history belongs to a blame frame, rather than its cursor-line commit.
local M = {}
local ns = vim.api.nvim_create_namespace('git_blame_file_info')
local RECENT = 12
local hl = {
  title = 'GitBlameFileTitle', heading = 'GitBlameFileHeading', label = 'GitBlameFileLabel',
  hash = 'GitBlameFileHash', author = 'GitBlameFileAuthor', date = 'GitBlameFileDate',
  count = 'GitBlameFileCount', subject = 'GitBlameFileSubject', added = 'GitBlameFileAdded',
  deleted = 'GitBlameFileDeleted', key = 'GitBlameFileKey', muted = 'Comment',
  path = 'Directory', warning = 'DiagnosticWarn',
}

local function setup_highlights()
  local links = { title = 'Title', heading = 'Type', label = 'Identifier', hash = 'String',
    author = 'Type', date = 'Directory', count = 'Number', subject = 'Normal',
    added = 'String', deleted = 'DiagnosticError', key = 'Special' }
  for role, target in pairs(links) do
    vim.api.nvim_set_hl(0, hl[role], { default = true, link = target })
  end
end

local function clean(value)
  return tostring(value or ''):gsub('%c', ' ')
end

local function parse_history(output, path)
  local fields = vim.split(output, '\0', { plain = true })
  local entries, current, i = {}, nil, 1
  while i <= #fields do
    local token = fields[i]
    if token:match('^%x+$') and #token >= 40 then
      current = { hash = token, author = fields[i + 1], email = fields[i + 2],
        date = fields[i + 3], age = fields[i + 4], subject = fields[i + 5], path = path }
      entries[#entries + 1] = current
      i = i + 6
    else
      local status = token:gsub('^\n+', '')
      if current and status:match('^[ACDMRTUXB]%d*$') then
        local old, new = fields[i + 1], nil
        if status:match('^[RC]') then new = fields[i + 2] end
        if (new or old) == path then
          current.status = status
          if new then
            current.previous_path = old
            path = old
          end
        end
        i = i + (new and 3 or 2)
      else
        i = i + 1
      end
    end
  end
  return entries
end

local function diff_summary(output)
  local added, removed, binary = 0, 0, false
  for _, item in ipairs(vim.split(output or '', '\0', { plain = true })) do
    local a, d = item:match('^(%d+)\t(%d+)\t')
    if a then added, removed = added + tonumber(a), removed + tonumber(d)
    elseif item:match('^%-\t%-\t') then binary = true end
  end
  if binary then return 'binary changes' end
  return added == 0 and removed == 0 and 'no line changes' or ('+%d / -%d lines'):format(added, removed)
end

-- All subprocess callbacks are scheduled, cancellable and scoped to this read.
function M.load(opts, callback)
  local jobs, cancelled, pending = {}, false, 0
  local data = { entries = {}, errors = {} }
  local function run(args, done)
    local argv = { 'git', '--no-optional-locks', '--literal-pathspecs', '-C', opts.root }
    vim.list_extend(argv, args)
    local job = vim.system(argv, { text = true }, function(result)
      vim.schedule(function() if not cancelled then done(result) end end)
    end)
    jobs[#jobs + 1] = job
  end
  local function error_message(result)
    return vim.trim(result.stderr or '') ~= '' and vim.trim(result.stderr) or 'Git exited with code ' .. result.code
  end
  run({ 'rev-parse', '--verify', (opts.revision or 'HEAD') .. '^{commit}' }, function(result)
    if result.code ~= 0 then callback(nil, error_message(result)); return end
    data.tip = vim.trim(result.stdout)
    local queries = {
      { key = 'history', args = { 'log', '--follow', '--topo-order', '--no-color', '--no-show-signature',
        '--format=%x00%H%x00%aN%x00%aE%x00%aI%x00%ar%x00%s%x00', '--name-status', '-z', data.tip, '--', opts.path } },
      { key = 'shallow', args = { 'rev-parse', '--is-shallow-repository' } },
    }
    if not opts.revision then
      for _, kind in ipairs({ 'staged', 'unstaged' }) do
        local args = { 'diff', '--no-ext-diff', '--no-textconv', '--no-renames', '--numstat', '-z' }
        if kind == 'staged' then vim.list_extend(args, { '--cached', data.tip }) end
        vim.list_extend(args, { '--', opts.path })
        queries[#queries + 1] = { key = kind, args = args }
      end
    end
    pending = #queries
    for _, query in ipairs(queries) do
      run(query.args, function(r)
        if r.code ~= 0 then data.errors[query.key] = error_message(r)
        elseif query.key == 'history' then data.entries = parse_history(r.stdout or '', opts.path)
        elseif query.key == 'shallow' then data.shallow = vim.trim(r.stdout) == 'true'
        else data[query.key] = diff_summary(r.stdout) end
        pending = pending - 1
        if pending == 0 then
          if data.errors.history then callback(nil, data.errors.history) else callback(data) end
        end
      end)
    end
  end)
  return { cancel = function()
    cancelled = true
    for _, job in ipairs(jobs) do pcall(job.kill, job, 15) end
  end }
end

local function render(opts, data, all)
  local lines, rows, highlights = {}, {}, {}
  local function mark(row, first, last, group, priority)
    if group and last > first then
      highlights[#highlights + 1] = { row = row - 1, col = first, end_col = last, group = group, priority = priority }
    end
  end
  local function add(line, entry, group)
    lines[#lines + 1] = line
    if entry then rows[#lines] = entry end
    mark(#lines, 0, #line, group)
  end
  -- Build byte ranges alongside the text: names, subjects and paths may contain
  -- Unicode or resemble dates/hashes without being those metadata fields.
  local function chunks(parts, entry)
    local text, col = {}, 0
    for _, part in ipairs(parts) do
      text[#text + 1] = part[1]
      mark(#lines + 1, col, col + #part[1], part[2])
      col = col + #part[1]
    end
    add(table.concat(text), entry)
  end
  local function field(label, value, group)
    chunks({ { label, hl.label }, { value, group } })
  end
  local function heading(title)
    add(title, nil, hl.heading)
  end
  local function commit(entry, prefix)
    chunks({ { prefix or '', hl.label }, { entry.hash:sub(1, 8), hl.hash }, { '  ' },
      { clean(entry.author), hl.author }, { '  ' }, { clean(entry.date):gsub('T', ' '), hl.date },
      { ' (' .. clean(entry.age) .. ')', hl.muted } }, entry)
    add('  ' .. clean(entry.subject), entry, hl.subject)
  end
  local function change(label, value, err)
    value = value or ('unavailable: ' .. clean(err))
    field(label, value, err and hl.warning or hl.muted)
    if not err then
      for pattern, group in pairs({ ['%+%d+'] = hl.added, ['%-%d+'] = hl.deleted }) do
        local first, last = value:find(pattern)
        if first then mark(#lines, #label + first - 1, #label + last, group, 130) end
      end
    end
  end
  add('File overview', nil, hl.title)
  field('Path:       ', clean(opts.path), hl.path)
  field('Repository: ', clean(opts.root), hl.muted)
  chunks({ { 'History at: ', hl.label },
    { opts.revision and opts.revision:sub(1, 12) or 'HEAD', hl.hash }, { ' · ', hl.muted },
    { data.tip:sub(1, 12), hl.hash } })
  chunks({ { 'Snapshot:   ', hl.label }, { tostring(#opts.frame.lines), hl.count },
    { ' lines' }, { opts.revision and ' (historical)' or ' (working tree)', hl.muted } })
  chunks({ { '<CR>', hl.key }, { ': inspect commit  ', hl.muted }, { 'y', hl.key },
    { ': copy hash  ', hl.muted }, { 'a', hl.key }, { ': recent/all  ', hl.muted },
    { 'R', hl.key }, { ': refresh  ', hl.muted }, { 'q / <Esc> / gh', hl.key }, { ': close', hl.muted } })
  add('')

  local authors, adds, renames = {}, 0, 0
  for _, entry in ipairs(data.entries) do
    local key = entry.email ~= '' and entry.email or entry.author
    authors[key] = authors[key] or { author = entry.author, email = entry.email, count = 0 }
    authors[key].count = authors[key].count + 1
    if entry.status == 'A' then adds = adds + 1 end
    if (entry.status or ''):match('^R') then renames = renames + 1 end
  end
  local contributors = vim.tbl_values(authors)
  table.sort(contributors, function(a, b)
    return a.count == b.count and a.email < b.email or a.count > b.count
  end)
  heading('History summary')
  chunks({ { 'Commits: ', hl.label }, { tostring(#data.entries), hl.count },
    { '   Changes after add: ', hl.label }, { tostring(#data.entries - adds), hl.count },
    { '   Authors: ', hl.label }, { tostring(#contributors), hl.count },
    { '   Renames: ', hl.label }, { tostring(renames), hl.count } })
  local latest, earliest = data.entries[1], data.entries[#data.entries]
  if latest then commit(latest, 'Last change: ') end
  if earliest then
    commit(earliest, earliest.status == 'A' and not data.shallow and 'First added: ' or 'Earliest available: ')
    if earliest.path ~= opts.path then field('Original path: ', clean(earliest.path), hl.path) end
  else add('No file history found at this revision.', nil, hl.muted) end
  add('')
  if not opts.revision then
    heading('Local changes')
    change('Staged:   ', data.staged, data.errors.staged)
    change('Unstaged: ', data.unstaged, data.errors.unstaged)
    local buf = opts.frame.code_buf
    local unsaved = buf and vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified
    field('Buffer:   ', unsaved and 'unsaved changes (not included in disk diff counts)' or 'no unsaved changes',
      unsaved and hl.warning or hl.muted)
    add('')
  end
  heading('Contributors · commits (mailmap applied)')
  for index = 1, math.min(#contributors, all and #contributors or 5) do
    local author = contributors[index]
    chunks({ { '  ' }, { tostring(author.count), hl.count }, { '  ' }, { clean(author.author), hl.author },
      { ' <' .. clean(author.email) .. '>', hl.muted } })
  end
  if not all and #contributors > 5 then add('  … a: show all contributors', nil, hl.muted) end
  add('')
  local limit = math.min(#data.entries, all and #data.entries or RECENT)
  heading(('Recent commits · %d / %d'):format(limit, #data.entries))
  for index = 1, limit do
    local entry = data.entries[index]
    commit(entry)
    if entry.previous_path then
      chunks({ { '  Rename: ', hl.label }, { clean(entry.previous_path), hl.path },
        { ' → ', hl.muted }, { clean(entry.path), hl.path } }, entry)
    end
  end
  add('')
  add('Reachable history only · detected renames followed · dates are author dates', nil, hl.muted)
  add('Commit counts include adds/renames; merge history follows git log --follow.', nil, hl.muted)
  if data.shallow then add('Shallow repository: counts and earliest history may be incomplete.', nil, hl.warning) end
  if data.errors.shallow then add('History completeness could not be checked: ' .. clean(data.errors.shallow), nil, hl.warning) end
  return lines, rows, highlights
end

function M.open(opts)
  setup_highlights()
  local state = { active = true, generation = 0 }
  local buf = vim.api.nvim_create_buf(false, true)
  state.buf = buf
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = 'nofile', 'wipe', false
  vim.bo[buf].filetype = 'gitblamefileinfo'
  local group = vim.api.nvim_create_augroup('GitBlameFileInfo' .. buf, { clear = true })
  local function config()
    local width = math.max(1, math.min(104, vim.o.columns - 4))
    local height = math.max(1, math.min(vim.o.lines - 6, 34))
    return { relative = 'editor', width = width, height = height,
      row = math.max(0, math.floor((vim.o.lines - height - 2) / 2)),
      col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
      style = 'minimal', border = 'single', title = ' File Git information · gh ', title_pos = 'center', zindex = 70 }
  end
  local function valid()
    return state.active and state.win and vim.api.nvim_win_is_valid(state.win) and vim.api.nvim_buf_is_valid(buf)
  end
  local function dispose()
    if not state.active then return end
    state.active = false
    if state.task then state.task.cancel(); state.task = nil end
    pcall(vim.api.nvim_del_augroup_by_id, group)
    if opts.on_close then opts.on_close() end
  end
  function state.close()
    local focused = vim.api.nvim_get_current_win() == state.win
    dispose()
    if state.win and vim.api.nvim_win_is_valid(state.win) then vim.api.nvim_win_close(state.win, true) end
    if focused and vim.api.nvim_win_is_valid(opts.return_win) then vim.api.nvim_set_current_win(opts.return_win) end
  end
  local function paint(lines, rows, highlights)
    if not valid() then return end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    state.rows = rows or {}
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, mark in ipairs(highlights or {}) do
      vim.api.nvim_buf_set_extmark(buf, ns, mark.row, mark.col,
        { end_col = mark.end_col, hl_group = mark.group, priority = mark.priority or 120 })
    end
  end
  local function refresh()
    if state.task then state.task.cancel(); state.task = nil end
    state.data = nil
    state.generation = state.generation + 1
    local generation = state.generation
    paint({ 'Loading file history…', '', 'q / <Esc> / gh: close' })
    state.task = M.load(opts, function(data, err)
      if not valid() or generation ~= state.generation then return end
      state.task = nil
      state.data = data
      if data then paint(render(opts, data, state.all))
      else paint({ 'Could not load file information', '', clean(err), '', 'R: retry  q / <Esc> / gh: close' }) end
    end)
  end
  state.win = vim.api.nvim_open_win(buf, true, config())
  for name, value in pairs({ wrap = true, linebreak = true, list = false, spell = false, scrollbind = false, cursorbind = false,
    winhighlight = 'FloatTitle:GitBlameFileTitle,FloatBorder:GitBlameFileLabel' }) do
    vim.api.nvim_set_option_value(name, value, { win = state.win, scope = 'local' })
  end
  local function map(keys, fn)
    for _, key in ipairs(keys) do vim.keymap.set('n', key, fn, { buffer = buf, silent = true, nowait = true }) end
  end
  map({ 'q', '<Esc>', 'gh' }, state.close)
  map({ 'R' }, refresh)
  map({ 'a' }, function()
    state.all = not state.all
    if state.data then paint(render(opts, state.data, state.all)) end
  end)
  map({ 'y', 'gy' }, function()
    local entry = state.rows[vim.api.nvim_win_get_cursor(state.win)[1]]
    if entry then vim.fn.setreg('"', entry.hash); vim.notify('Copied ' .. entry.hash, vim.log.levels.INFO) end
  end)
  map({ '<CR>' }, function()
    local entry = state.rows[vim.api.nvim_win_get_cursor(state.win)[1]]
    if not entry then return end
    state.close()
    local commit = require('git.features.commit')
    local b = commit.open({ work_tree = opts.root, revision = entry.hash, tab = true })
    if b then vim.w.git_commit_return_win = opts.return_win; commit.expand_file(b, entry.path) end
  end)
  vim.api.nvim_create_autocmd('VimResized', { group = group, callback = function()
    if valid() then vim.api.nvim_win_set_config(state.win, config()) end
  end })
  vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = setup_highlights })
  vim.api.nvim_create_autocmd({ 'WinLeave', 'BufWipeout' }, { group = group, buffer = buf, callback = function()
    if state.active then vim.schedule(state.close) end
  end })
  refresh()
  return state
end

return M
