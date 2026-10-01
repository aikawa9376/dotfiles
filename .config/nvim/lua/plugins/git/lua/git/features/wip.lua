-- Opt-in snapshots of tracked index/worktree changes, stored outside refs/stash.
local M = {}
local utils = require('git.utils')
local pending = {}

local function run(root, args)
  local cmd = { 'git' }
  vim.list_extend(cmd, args)
  return vim.system(cmd, { cwd = root, text = true }):wait()
end

local function value(root, args)
  local result = run(root, args)
  return result.code == 0 and vim.trim(result.stdout or '') or nil
end

local function error_text(result)
  return vim.trim((result.stderr or '') ~= '' and result.stderr or result.stdout or 'Git command failed')
end

function M.ref(root)
  local branch = value(root, { 'symbolic-ref', '--quiet', '--short', 'HEAD' })
  if not branch or branch == '' then return nil, 'WIP snapshots need a checked-out branch' end
  return 'refs/git-ui/wip/' .. vim.fn.sha256(branch), branch
end

local function identity(root, commit)
  if not commit then return nil end
  return value(root, { 'rev-parse', commit .. '^1', commit .. '^2^{tree}', commit .. '^{tree}' })
end

function M.save(root)
  local ref, branch = M.ref(root)
  if not ref then return false, branch end
  if require('git.features.operation').inspect(root) then
    return false, 'Finish the current Git operation before saving WIP'
  end
  local status = run(root, { '--no-optional-locks', 'status', '--porcelain=v1', '-uno' })
  if status.code ~= 0 then return false, error_text(status) end
  if status.stdout == '' then return false, 'No tracked changes to save' end
  local created = run(root, { 'stash', 'create', 'git-ui WIP on ' .. branch })
  if created.code ~= 0 then return false, error_text(created) end
  local commit = vim.trim(created.stdout or '')
  if commit == '' then return false, 'No tracked changes to save' end
  local previous = value(root, { 'rev-parse', '--verify', ref })
  if previous and identity(root, previous) == identity(root, commit) then return true, 'unchanged' end
  local args = { 'update-ref', '--create-reflog', '-m', 'git-ui WIP snapshot', ref, commit }
  if previous then table.insert(args, previous) end
  local updated = run(root, args)
  if updated.code ~= 0 then return false, error_text(updated) end
  return true, commit
end

function M.list(root)
  local ref, err = M.ref(root)
  if not ref then return nil, err end
  local result = run(root, { 'reflog', 'show', '-n', '30', '--format=%H%x09%gd%x09%cr', ref })
  if result.code ~= 0 then return {}, nil end
  local entries = {}
  for line in (result.stdout or ''):gmatch('[^\n]+') do
    local hash, selector, age = line:match('^([a-f0-9]+)\t([^\t]+)\t(.*)$')
    if hash then entries[#entries + 1] = { hash = hash, selector = selector, age = age } end
  end
  return entries
end

function M.restore(root, selector)
  local ref, err = M.ref(root)
  if not ref then return false, err end
  if selector and not tostring(selector):match('^%d+$') then return false, 'Use a WIP snapshot number' end
  local revision = ref .. '@{' .. (selector or '0') .. '}'
  if not value(root, { 'rev-parse', '--verify', revision }) then return false, 'WIP snapshot not found' end
  local status = run(root, { '--no-optional-locks', 'status', '--porcelain=v1', '-uno' })
  if status.code ~= 0 then return false, error_text(status) end
  if status.stdout ~= '' then return false, 'Commit or stash tracked changes before restoring WIP' end
  local applied = run(root, { 'stash', 'apply', '--index', revision })
  if applied.code ~= 0 then return false, error_text(applied) end
  utils.fire_fugitive_changed({ work_tree = root })
  return true
end

local function schedule(root)
  if not vim.g.git_wip_enabled or not root then return end
  pending[root] = (pending[root] or 0) + 1
  local generation = pending[root]
  vim.defer_fn(function()
    if pending[root] ~= generation or not vim.g.git_wip_enabled then return end
    pending[root] = nil
    local ok, err = M.save(root)
    if not ok and err ~= 'No tracked changes to save' then
      vim.notify('WIP snapshot: ' .. err, vim.log.levels.WARN)
    end
  end, 750)
end

local function open_log(root)
  local entries, err = M.list(root)
  if not entries then vim.notify(err, vim.log.levels.WARN); return end
  if #entries == 0 then vim.notify('No WIP snapshots for this branch', vim.log.levels.INFO); return end
  utils.open_panel_split()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, buf)
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].filetype = 'nofile', 'wipe', 'gitwip'
  utils.set_buf_work_tree(buf, root)
  local function refresh()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local selected = entries[row - 1]
    local next_entries, list_error = M.list(root)
    if not next_entries then vim.notify(list_error, vim.log.levels.WARN); return end
    entries = next_entries
    vim.b[buf].git_wip_entries = entries
    local lines = { 'WIP snapshots — Enter inspect, a restore, gy copy, R refresh, ? help, q close' }
    local selected_row
    for index, entry in ipairs(entries) do
      lines[#lines + 1] = ('%2d  %s  %s'):format(index - 1, entry.hash:sub(1, 12), entry.age)
      if selected and selected.hash == entry.hash then selected_row = index + 1 end
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_win_set_cursor(0, { selected_row or math.min(row, #lines), 0 })
  end
  refresh()
  vim.keymap.set('n', 'q', '<Cmd>close<CR>', { buffer = buf, silent = true, desc = 'Close WIP snapshots' })
  vim.keymap.set('n', '<CR>', function()
    local entry = entries[vim.api.nvim_win_get_cursor(0)[1] - 1]
    if entry then require('git.features.commit').open({ work_tree = root, revision = entry.hash }) end
  end, { buffer = buf, silent = true, desc = 'Inspect selected snapshot' })
  vim.keymap.set('n', 'a', function()
    local number = vim.api.nvim_win_get_cursor(0)[1] - 2
    local entry = entries[number + 1]
    if not entry then return end
    if vim.fn.confirm('Restore WIP snapshot ' .. number .. ' (' .. entry.hash:sub(1, 7) .. ')?', '&Restore\n&Cancel', 2) ~= 1 then return end
    local current = M.list(root)
    if not current or not current[number + 1] or current[number + 1].hash ~= entry.hash then
      vim.notify('WIP history changed; refresh and select the snapshot again', vim.log.levels.WARN); return
    end
    local ok, restore_err = M.restore(root, tostring(number))
    vim.notify(ok and 'WIP snapshot restored' or restore_err, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
  end, { buffer = buf, silent = true, desc = 'Restore selected snapshot and its index state' })
  vim.keymap.set('n', 'R', refresh, { buffer = buf, silent = true, desc = 'Refresh WIP snapshots' })
  require('git.features.panel_keys').configure(buf, { context = function()
    local entry = entries[vim.api.nvim_win_get_cursor(0)[1] - 1]
    if entry then return { kind = 'snapshot', commit = entry.hash, value = entry.hash:sub(1, 7), label = entry.hash:sub(1, 7) } end
    return { kind = 'repository', label = 'WIP snapshots' }
  end })
  return buf
end
M.open = open_log

function M.setup(group)
  vim.api.nvim_create_user_command('GitWipEnable', function()
    vim.g.git_wip_enabled = true
    schedule(utils.get_work_tree())
    vim.notify('Automatic WIP snapshots enabled', vim.log.levels.INFO)
  end, {})
  vim.api.nvim_create_user_command('GitWipDisable', function()
    vim.g.git_wip_enabled = false
    vim.notify('Automatic WIP snapshots disabled', vim.log.levels.INFO)
  end, {})
  vim.api.nvim_create_user_command('GitWipSave', function()
    local root = utils.get_work_tree({ notify = true })
    if not root then return end
    local ok, result = M.save(root)
    vim.notify(ok and (result == 'unchanged' and 'WIP snapshot unchanged' or 'WIP snapshot saved') or result,
      ok and vim.log.levels.INFO or vim.log.levels.WARN)
  end, {})
  vim.api.nvim_create_user_command('GitWipLog', function()
    local root = utils.get_work_tree({ notify = true })
    if root then open_log(root) end
  end, {})
  vim.api.nvim_create_user_command('GitWipRestore', function(opts)
    local root = utils.get_work_tree({ notify = true })
    if not root then return end
    local ok, err = M.restore(root, opts.args ~= '' and opts.args or nil)
    vim.notify(ok and 'WIP snapshot restored' or err, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
  end, { nargs = '?' })
  vim.api.nvim_create_autocmd('BufWritePost', { group = group, callback = function(ev)
    if not vim.g.git_wip_enabled then return end
    local name = vim.api.nvim_buf_get_name(ev.buf)
    if name == '' or name:match('^%w[%w-]*://') then return end
    schedule(utils.get_buf_work_tree(ev.buf))
  end })
  vim.api.nvim_create_autocmd('User', { group = group, pattern = 'FugitiveChanged', callback = function(ev)
    schedule(ev.data and ev.data.work_tree)
  end })
end

return M
