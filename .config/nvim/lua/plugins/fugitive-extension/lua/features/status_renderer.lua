local M = {}

local models = {}
local expanded = {}

local function run(work_tree, args)
  local command = { 'git' }
  vim.list_extend(command, args)
  return vim.system(command, { cwd = work_tree, text = true }):wait()
end

local function split_nul(value)
  return vim.split(value or '', '\0', { plain = true, trimempty = true })
end

local function display_status(status)
  return status == '.' and ' ' or status
end

local function parse_status(work_tree)
  local result = run(work_tree, {
    'status', '--porcelain=v2', '-z', '--branch', '--untracked-files=normal',
  })
  if result.code ~= 0 then return nil, vim.trim(result.stderr or 'git status failed') end

  local model = {
    work_tree = work_tree,
    branch = nil,
    oid = nil,
    upstream = nil,
    push = nil,
    ahead = 0,
    behind = 0,
    staged = {},
    unstaged = {},
    untracked = {},
    conflicted = {},
  }
  local records = split_nul(result.stdout)
  local index = 1
  while index <= #records do
    local record = records[index]
    if record:sub(1, 2) == '# ' then
      local key, value = record:match('^# ([^ ]+) (.*)$')
      if key == 'branch.oid' then model.oid = value
      elseif key == 'branch.head' then model.branch = value
      elseif key == 'branch.upstream' then model.upstream = value
      elseif key == 'branch.ab' then
        model.ahead = tonumber(value:match('%+(%d+)')) or 0
        model.behind = tonumber(value:match('%-(%d+)')) or 0
      end
    elseif record:sub(1, 2) == '1 ' then
      local xy, path = record:match('^1 ([^ ]+) [^ ]+ [^ ]+ [^ ]+ [^ ]+ [^ ]+ [^ ]+ (.*)$')
      if xy and path then
        local x, y = xy:sub(1, 1), xy:sub(2, 2)
        if x ~= '.' then table.insert(model.staged, { section = 'staged', status = x, path = path }) end
        if y ~= '.' then table.insert(model.unstaged, { section = 'unstaged', status = y, path = path }) end
      end
    elseif record:sub(1, 2) == '2 ' then
      local xy, path = record:match('^2 ([^ ]+) [^ ]+ [^ ]+ [^ ]+ [^ ]+ [^ ]+ [^ ]+ [^ ]+ (.*)$')
      local old_path = records[index + 1]
      if xy and path and old_path then
        index = index + 1
        local x, y = xy:sub(1, 1), xy:sub(2, 2)
        local display_path = old_path .. ' -> ' .. path
        if x ~= '.' then
          table.insert(model.staged, { section = 'staged', status = x, path = path, old_path = old_path, display_path = display_path })
        end
        if y ~= '.' then
          table.insert(model.unstaged, { section = 'unstaged', status = y, path = path, old_path = old_path, display_path = display_path })
        end
      end
    elseif record:sub(1, 2) == 'u ' then
      local xy, path = record:match('^u ([^ ]+) [^ ]+ [^ ]+ [^ ]+ [^ ]+ [^ ]+ [^ ]+ [^ ]+ (.*)$')
      if xy and path then
        table.insert(model.conflicted, { section = 'conflicted', status = xy, path = path })
      end
    elseif record:sub(1, 2) == '? ' then
      table.insert(model.untracked, { section = 'untracked', status = '?', path = record:sub(3) })
    end
    index = index + 1
  end
  local push_result = run(work_tree, { 'rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{push}' })
  if push_result.code == 0 then model.push = vim.trim(push_result.stdout or '') end
  if not model.push or model.push == '' then model.push = model.upstream end
  return model
end

local function diff_lines(model, entry)
  if entry.section == 'untracked' then
    local paths = { entry.path }
    local absolute = vim.fs.joinpath(model.work_tree, entry.path)
    if vim.fn.isdirectory(absolute) == 1 then
      local result = run(model.work_tree, {
        'ls-files', '--others', '--exclude-standard', '--', entry.path,
      })
      paths = result.code == 0 and vim.split(vim.trim(result.stdout or ''), '\n', { plain = true, trimempty = true }) or {}
    end

    local lines = {}
    for _, path in ipairs(paths) do
      local filename = vim.fs.joinpath(model.work_tree, path)
      local ok, content = pcall(vim.fn.readfile, filename, 'b')
      if ok then
        table.insert(lines, ('@@ new file: %s (%d lines) @@'):format(path, #content))
        for _, line in ipairs(content) do table.insert(lines, '+' .. line) end
      end
    end
    return lines
  end

  local args = { 'diff', '--no-ext-diff', '--no-color' }
  if entry.section == 'staged' then table.insert(args, '--cached') end
  vim.list_extend(args, { '--', entry.path })
  local result = run(model.work_tree, args)
  if result.code ~= 0 then return {} end
  local all_lines, hunk_start = {}, nil
  for line in (result.stdout or ''):gmatch('[^\r\n]+') do
    table.insert(all_lines, line)
    if not hunk_start and line:match('^@@') then hunk_start = #all_lines end
  end
  if not hunk_start then return all_lines end
  local lines = {}
  for index = hunk_start, #all_lines do table.insert(lines, all_lines[index]) end
  return lines
end

local function entry_key(entry)
  return entry.section .. '\0' .. entry.path
end

local function append_section(lines, entries_by_row, model, title, section, entries)
  if #entries == 0 then return end
  table.insert(lines, '')
  table.insert(lines, ('%s (%d)'):format(title, #entries))
  entries_by_row[#lines] = { section = section, header = true }
  for _, entry in ipairs(entries) do
    local path = entry.display_path or entry.path
    table.insert(lines, display_status(entry.status) .. ' ' .. path)
    entries_by_row[#lines] = entry
    if expanded[model.bufnr] and expanded[model.bufnr][entry_key(entry)] then
      for _, diff_line in ipairs(diff_lines(model, entry)) do
        table.insert(lines, diff_line)
        entries_by_row[#lines] = entry
      end
    end
  end
end

local function operation_lines(work_tree)
  local git_dir_result = run(work_tree, { 'rev-parse', '--git-dir' })
  if git_dir_result.code ~= 0 then return {} end
  local git_dir = vim.trim(git_dir_result.stdout or '')
  if not vim.startswith(git_dir, '/') then git_dir = work_tree .. '/' .. git_dir end
  if vim.fn.isdirectory(git_dir .. '/rebase-merge') == 1 or vim.fn.isdirectory(git_dir .. '/rebase-apply') == 1 then
    return { 'Rebase in progress' }
  elseif vim.fn.filereadable(git_dir .. '/CHERRY_PICK_HEAD') == 1 then
    return { 'Cherry-pick in progress' }
  elseif vim.fn.filereadable(git_dir .. '/MERGE_HEAD') == 1 then
    return { 'Merge in progress' }
  elseif vim.fn.filereadable(git_dir .. '/REVERT_HEAD') == 1 then
    return { 'Revert in progress' }
  end
  return {}
end

local function commit_lines(work_tree, revisions)
  local args = { 'log', '--pretty=format:%h%x09%s', '-n', '256' }
  if type(revisions) == 'table' then
    vim.list_extend(args, revisions)
  else
    table.insert(args, revisions)
  end
  table.insert(args, '--')
  local result = run(work_tree, args)
  if result.code ~= 0 then return {}, false end
  local commits = {}
  for line in (result.stdout or ''):gmatch('[^\r\n]+') do
    table.insert(commits, (line:gsub('\t', ' ', 1)))
  end
  return commits, true
end

function M.take_ownership(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  vim.b[bufnr].custom_git_status = true
end

function M.is_owned(bufnr)
  return vim.api.nvim_buf_is_valid(bufnr) and vim.b[bufnr].custom_git_status == true
end

function M.snapshot(bufnr, work_tree)
  if not vim.api.nvim_buf_is_valid(bufnr) then return nil, 'Invalid status buffer' end
  local model, err = parse_status(work_tree)
  if not model then return nil, err end
  model.bufnr = bufnr

  local lines = {
    'Head: ' .. ((model.branch and model.branch ~= '(detached)') and model.branch or (model.oid or 'unknown'):sub(1, 12)),
  }
  if model.upstream then
    table.insert(lines, ('Upstream: %s (+%d/-%d)'):format(model.upstream, model.ahead, model.behind))
  end
  if model.push and model.push ~= model.upstream then table.insert(lines, 'Push: ' .. model.push) end
  for _, line in ipairs(operation_lines(work_tree)) do table.insert(lines, line) end
  table.insert(lines, 'Help: g?')

  if model.upstream and model.behind > 0 then
    local unpulled = commit_lines(work_tree, 'HEAD..' .. model.upstream)
    table.insert(lines, '')
    table.insert(lines, ('Unpulled from %s (%d)'):format(model.upstream, #unpulled))
    vim.list_extend(lines, unpulled)
  end

  local entries_by_row = {}
  append_section(lines, entries_by_row, model, 'Unmerged paths', 'conflicted', model.conflicted)
  append_section(lines, entries_by_row, model, 'Untracked files', 'untracked', model.untracked)
  append_section(lines, entries_by_row, model, 'Unstaged changes', 'unstaged', model.unstaged)
  append_section(lines, entries_by_row, model, 'Staged changes', 'staged', model.staged)
  model.entries_by_row = entries_by_row
  models[bufnr] = model
  M.take_ownership(bufnr)
  return lines
end

function M.entry_at(bufnr, row)
  local model = models[bufnr]
  return model and model.entries_by_row[row] or nil
end

function M.entry_row(bufnr, row)
  local model = models[bufnr]
  local entry = M.entry_at(bufnr, row)
  if not model or not entry then return nil end
  local direct_row
  for candidate, value in pairs(model.entries_by_row) do
    if value == entry and (not direct_row or candidate < direct_row) then direct_row = candidate end
  end
  return direct_row
end

function M.paths_in_range(bufnr, first_row, last_row)
  local model = models[bufnr]
  if not model then return {} end
  local paths, seen = {}, {}
  for row = first_row, last_row do
    local entry = model.entries_by_row[row]
    if entry and not entry.header and entry.path and not seen[entry.path] then
      seen[entry.path] = true
      table.insert(paths, entry.path)
    end
  end
  return paths
end

function M.unpushed_commits(bufnr)
  local model = models[bufnr]
  if not model then return {} end
  if model.push then
    local commits, ok = commit_lines(model.work_tree, model.push .. '..HEAD')
    if ok then return commits end
  end

  local remotes = run(model.work_tree, { 'remote' })
  if remotes.code ~= 0 or vim.trim(remotes.stdout or '') == '' then return {} end
  return commit_lines(model.work_tree, { 'HEAD', '--not', '--remotes' })
end

local section_entries

function M.toggle_diff(bufnr, row)
  local entry = M.entry_at(bufnr, row)
  if not entry then return false end
  expanded[bufnr] = expanded[bufnr] or {}
  if entry.header then
    local entries = section_entries(models[bufnr], entry.section)
    local expand = false
    for _, item in ipairs(entries) do
      if not expanded[bufnr][entry_key(item)] then expand = true; break end
    end
    for _, item in ipairs(entries) do expanded[bufnr][entry_key(item)] = expand end
    return #entries > 0
  end
  local key = entry_key(entry)
  expanded[bufnr][key] = not expanded[bufnr][key]
  return true
end

function M.set_diff(bufnr, row, value)
  local entry = M.entry_at(bufnr, row)
  if not entry then return false end
  expanded[bufnr] = expanded[bufnr] or {}
  if entry.header then
    local entries = section_entries(models[bufnr], entry.section)
    for _, item in ipairs(entries) do expanded[bufnr][entry_key(item)] = value end
    return #entries > 0
  end
  expanded[bufnr][entry_key(entry)] = value
  return true
end

section_entries = function(model, section)
  if section == 'staged' then return model.staged end
  if section == 'unstaged' then return model.unstaged end
  if section == 'untracked' then return model.untracked end
  if section == 'conflicted' then return model.conflicted end
  return {}
end

local function update_entry_rows(model, direct_row, end_row, entry, replacement_count)
  local removed = end_row - direct_row
  local delta = replacement_count - removed
  local updated = {}
  for old_row, value in pairs(model.entries_by_row) do
    if old_row <= direct_row then
      updated[old_row] = value
    elseif old_row > end_row then
      updated[old_row + delta] = value
    end
  end
  for offset = 1, replacement_count do updated[direct_row + offset] = entry end
  model.entries_by_row = updated
end

local function direct_row_for_entry(model, entry)
  local row
  for candidate, value in pairs(model.entries_by_row) do
    if value == entry and (not row or candidate < row) then row = candidate end
  end
  return row
end

function M.update_diff(bufnr, row, mode)
  local model = models[bufnr]
  local selected = M.entry_at(bufnr, row)
  if not model or not selected then return false end
  local entries = selected.header and section_entries(model, selected.section) or { selected }
  if #entries == 0 then return false end

  expanded[bufnr] = expanded[bufnr] or {}
  local expand = mode == 'show'
  if mode == 'toggle' then
    expand = false
    for _, entry in ipairs(entries) do
      if not expanded[bufnr][entry_key(entry)] then expand = true; break end
    end
  end
  local changed_entries = {}
  for _, entry in ipairs(entries) do
    local key = entry_key(entry)
    if expanded[bufnr][key] ~= expand then table.insert(changed_entries, entry) end
    expanded[bufnr][key] = expand
  end
  if #changed_entries == 0 then return true end

  local ordered = {}
  for _, entry in ipairs(changed_entries) do
    local direct_row = direct_row_for_entry(model, entry)
    if direct_row then table.insert(ordered, { entry = entry, row = direct_row }) end
  end
  table.sort(ordered, function(left, right) return left.row > right.row end)

  local previous_modifiable = vim.bo[bufnr].modifiable
  local previous_readonly = vim.bo[bufnr].readonly
  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].readonly = false
  local ok, err = pcall(function()
    for _, item in ipairs(ordered) do
      local direct_row = direct_row_for_entry(model, item.entry)
      local end_row = direct_row
      while model.entries_by_row[end_row + 1] == item.entry do end_row = end_row + 1 end
      local replacement = expand and diff_lines(model, item.entry) or {}
      vim.api.nvim_buf_set_lines(bufnr, direct_row, end_row, false, replacement)
      update_entry_rows(model, direct_row, end_row, item.entry, #replacement)
    end
  end)
  vim.bo[bufnr].modifiable = previous_modifiable
  vim.bo[bufnr].readonly = previous_readonly
  vim.bo[bufnr].modified = false
  if not ok then
    vim.notify('Failed to update inline diff: ' .. tostring(err), vim.log.levels.ERROR)
    return false
  end
  return true
end

local function change_entries(model, entries, action)
  if #entries == 0 then return false, 'Section is empty' end
  local stage_paths, unstage_paths = {}, {}
  local stage_seen, unstage_seen = {}, {}
  for _, item in ipairs(entries) do
    local should_stage = action == 'stage' or (action == 'toggle' and item.section ~= 'staged')
    local should_unstage = action == 'unstage' or (action == 'toggle' and item.section == 'staged')
    if should_stage and item.section ~= 'staged' and not stage_seen[item.path] then
      stage_seen[item.path] = true
      table.insert(stage_paths, item.path)
    elseif should_unstage and item.section == 'staged' and not unstage_seen[item.path] then
      unstage_seen[item.path] = true
      table.insert(unstage_paths, item.path)
    end
  end
  if #stage_paths == 0 and #unstage_paths == 0 then return false, 'Nothing to update here' end

  if #stage_paths > 0 then
    local args = { 'add', '--' }
    vim.list_extend(args, stage_paths)
    local result = run(model.work_tree, args)
    if result.code ~= 0 then return false, vim.trim(result.stderr or 'Git add failed') end
  end
  if #unstage_paths > 0 then
    local args = { 'restore', '--staged', '--' }
    vim.list_extend(args, unstage_paths)
    local result = run(model.work_tree, args)
    if result.code ~= 0 then
      args = { 'reset', '--' }
      vim.list_extend(args, unstage_paths)
      result = run(model.work_tree, args)
    end
    if result.code ~= 0 then return false, vim.trim(result.stderr or 'Git reset failed') end
  end
  return true
end

function M.change_index(bufnr, row, action)
  local model = models[bufnr]
  local entry = M.entry_at(bufnr, row)
  if not model or not entry then return false, 'No status entry at cursor' end
  local entries = entry.header and section_entries(model, entry.section) or { entry }
  return change_entries(model, entries, action)
end

function M.change_index_range(bufnr, first_row, last_row, action)
  local model = models[bufnr]
  if not model then return false, 'Status model is unavailable' end
  local entries = {}
  for row = first_row, last_row do
    local entry = M.entry_at(bufnr, row)
    if entry and not entry.header then table.insert(entries, entry) end
  end
  return change_entries(model, entries, action)
end

function M.reset_index(bufnr)
  local model = models[bufnr]
  if not model then return false, 'Status model is unavailable' end
  local result = run(model.work_tree, { 'reset', '--quiet' })
  if result.code ~= 0 then return false, vim.trim(result.stderr or 'Git reset failed') end
  return true
end

function M.stage_all(bufnr)
  local model = models[bufnr]
  if not model then return false, 'Status model is unavailable' end
  local result = run(model.work_tree, { 'add', '-A' })
  if result.code ~= 0 then return false, vim.trim(result.stderr or 'Git add failed') end
  return true
end

function M.collapse_all(bufnr)
  if not models[bufnr] then return false end
  expanded[bufnr] = {}
  return true
end

function M.discard(bufnr, row)
  local model = models[bufnr]
  local entry = M.entry_at(bufnr, row)
  if not model or not entry or entry.header then return false, 'No status entry at cursor' end
  if entry.section == 'conflicted' then return false, 'Resolve the conflict before discarding it' end
  if entry.section == 'untracked' then
    local absolute = vim.fs.joinpath(model.work_tree, entry.path)
    local flags = vim.fn.isdirectory(absolute) == 1 and 'rf' or ''
    if vim.fn.delete(absolute, flags) ~= 0 then return false, 'Failed to delete ' .. entry.path end
    return true
  end

  local args = { 'restore' }
  if entry.section == 'staged' then vim.list_extend(args, { '--staged', '--worktree' }) end
  vim.list_extend(args, { '--', entry.path })
  local result = run(model.work_tree, args)
  if result.code ~= 0 then return false, vim.trim(result.stderr or 'Git restore failed') end
  return true
end

function M.patch_command(bufnr, row)
  local entry = M.entry_at(bufnr, row)
  if not entry then return nil, 'No status entry at cursor' end
  local args
  if entry.section == 'staged' then
    args = 'Git reset --patch'
  elseif entry.section == 'unstaged' or entry.section == 'conflicted' then
    args = 'Git add --patch'
  elseif entry.section == 'untracked' then
    args = 'Git add --interactive'
  else
    return nil, 'Patch mode is unavailable here'
  end
  if not entry.header then args = args .. ' -- ' .. vim.fn.fnameescape(entry.path) end
  return 'tab ' .. args
end

local function blob_lines(model, revision, path)
  local result = run(model.work_tree, { 'show', revision .. ':' .. path })
  if result.code ~= 0 then return {} end
  local value = (result.stdout or ''):gsub('\r\n', '\n')
  local lines = vim.split(value, '\n', { plain = true })
  if lines[#lines] == '' then table.remove(lines) end
  return lines
end

local function worktree_lines(model, path)
  local absolute = vim.fs.joinpath(model.work_tree, path)
  if vim.fn.filereadable(absolute) ~= 1 then return {} end
  local ok, lines = pcall(vim.fn.readfile, absolute, 'b')
  return ok and lines or {}
end

function M.diff_sides(bufnr, row)
  local model = models[bufnr]
  local entry = M.entry_at(bufnr, row)
  if not model or not entry or entry.header then return nil, 'No status entry at cursor' end
  if vim.fn.isdirectory(vim.fs.joinpath(model.work_tree, entry.path)) == 1 then
    return nil, 'Cannot diff a directory'
  end

  if entry.section == 'staged' then
    return {
      path = entry.path,
      left = blob_lines(model, 'HEAD', entry.old_path or entry.path),
      right = blob_lines(model, '', entry.path),
      left_label = 'HEAD',
      right_label = 'index',
    }
  end
  return {
    path = entry.path,
    left = entry.section == 'untracked' and {} or blob_lines(model, '', entry.path),
    right = worktree_lines(model, entry.path),
    left_label = entry.section == 'untracked' and 'empty' or 'index',
    right_label = 'worktree',
  }
end

function M.cleanup(bufnr)
  models[bufnr] = nil
  expanded[bufnr] = nil
end

return M
