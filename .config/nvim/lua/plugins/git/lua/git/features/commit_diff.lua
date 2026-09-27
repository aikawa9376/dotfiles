-- Diff the commits represented by a Visual selection in a history panel.
local M = {}

local function run(root, args)
  local command = { 'git' }
  vim.list_extend(command, args)
  return vim.system(command, { cwd = root, text = true }):wait()
end

function M.visual_rows()
  local first = math.min(vim.fn.line('v'), vim.fn.line('.'))
  local last = math.max(vim.fn.line('v'), vim.fn.line('.'))
  vim.cmd('normal! \27')
  return first, last
end

function M.selected_commits(bufnr, commit_at_row)
  local first, last = M.visual_rows()
  local commits = {}
  for row = first, last do
    local commit = commit_at_row(bufnr, row)
    if not commit then return nil, 'Select only commit rows' end
    if commits[#commits] ~= commit then commits[#commits + 1] = commit end
  end
  return commits
end

function M.status_items(bufnr, first, last)
  local renderer = require('git.features.status_renderer')
  local kind, values, section = nil, {}, nil
  for row = first, last do
    local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ''
    local entry = renderer.entry_at(bufnr, row)
    local commit = line:match('^(%x%x%x%x%x%x%x+)%s')
    local stash = line:match('^%s*(stash@%{%d+%})')
    local current_kind, value
    if commit then
      current_kind, value = 'commits', commit
    elseif stash then
      current_kind, value = 'stashes', stash
    elseif entry and not entry.header and renderer.entry_row(bufnr, row) == row then
      current_kind, value = 'paths', entry.path
      if section and section ~= entry.section then return nil, 'Select files from one status section' end
      section = entry.section
    else
      return nil, 'Select only commit rows or file rows'
    end
    if kind and kind ~= current_kind then return nil, 'Select one kind of status row' end
    kind = current_kind
    if values[#values] ~= value then values[#values + 1] = value end
  end
  return { kind = kind, values = values, section = section, first = first, last = last }
end

local function open_revisions(root, base, tip)
  vim.schedule(function()
    vim.cmd('DiffviewOpen -C' .. vim.fn.fnameescape(root) .. ' ' .. base .. '..' .. tip)
  end)
  return true
end

function M.open_stashes(root, refs)
  if not root then return false, 'Git work tree not found' end
  if #refs == 0 then return false, 'No stash in selection' end
  local hashes = {}
  for _, ref in ipairs(refs) do
    local result = run(root, { 'rev-parse', '--verify', ref .. '^{commit}' })
    if result.code ~= 0 then return false, 'Stash is no longer available: ' .. ref end
    hashes[#hashes + 1] = vim.trim(result.stdout)
  end
  local newest, oldest = hashes[1], hashes[#hashes]
  local base = oldest
  if #hashes == 1 then
    local parent = run(root, { 'rev-parse', '--verify', oldest .. '^1' })
    if parent.code ~= 0 then return false, 'Stash base is unavailable: ' .. refs[1] end
    base = vim.trim(parent.stdout)
  end
  return open_revisions(root, base, newest)
end

function M.open_paths(root, paths, section)
  if not root then return false, 'Git work tree not found' end
  if #paths == 0 then return false, 'No files in selection' end
  local command = 'DiffviewOpen -C' .. vim.fn.fnameescape(root)
  if section == 'staged' then command = command .. ' --cached' end
  if section == 'untracked' then command = command .. ' --untracked-files=true' end
  command = command .. ' --'
  for _, path in ipairs(paths) do command = command .. ' ' .. vim.fn.fnameescape(path) end
  vim.schedule(function() vim.cmd(command) end)
  return true
end

function M.open_selected(root, commits, selected_file)
  if not root then return false, 'Git work tree not found' end
  if #commits == 0 then return false, 'No commits in selection' end
  local resolved = {}
  for _, commit in ipairs(commits) do
    local result = run(root, { 'rev-parse', '--verify', commit .. '^{commit}' })
    if result.code ~= 0 then return false, 'Selected commit is no longer available: ' .. commit end
    resolved[#resolved + 1] = vim.trim(result.stdout)
  end
  local newest, oldest = resolved[1], resolved[1]
  for index = 2, #resolved do
    local commit = resolved[index]
    if run(root, { 'merge-base', '--is-ancestor', commit, oldest }).code == 0 then
      oldest = commit
    end
    if run(root, { 'merge-base', '--is-ancestor', newest, commit }).code == 0 then
      newest = commit
    end
  end
  for _, commit in ipairs(resolved) do
    if run(root, { 'merge-base', '--is-ancestor', oldest, commit }).code ~= 0
      or run(root, { 'merge-base', '--is-ancestor', commit, newest }).code ~= 0 then
      return false, 'Selected commits are not on one ancestry chain'
    end
  end
  local parent = run(root, { 'rev-parse', '--verify', oldest .. '^' })
  local base
  if parent.code == 0 then
    base = vim.trim(parent.stdout)
  else
    local empty = run(root, { 'hash-object', '-t', 'tree', '--stdin' })
    if empty.code ~= 0 then return false, vim.trim(empty.stderr or 'Could not create empty tree') end
    base = vim.trim(empty.stdout)
  end
  if not selected_file then return open_revisions(root, base, newest) end
  local command = 'DiffviewOpen -C' .. vim.fn.fnameescape(root) .. ' ' .. base .. '..' .. newest
    .. ' --selected-file=' .. vim.fn.fnameescape(selected_file)
  vim.schedule(function() vim.cmd(command) end)
  return true
end

return M
