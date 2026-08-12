local M = {}
local utils = require('fugitive_utils')
local commands = require('features.commands')
local help = require('features.help')

local entries_by_buf = {}
local rows_by_hash_by_buf = {}
local static_ns = vim.api.nvim_create_namespace('fugitive_reflog_static')
local linked_ns = vim.api.nvim_create_namespace('fugitive_reflog_linked')

local function run(work_tree, args)
  local command = { 'git' }
  vim.list_extend(command, args)
  return vim.system(command, { cwd = work_tree, text = true }):wait()
end

local function age_label(timestamp)
  local seconds = math.max(os.time() - timestamp, 0)
  if seconds < 60 then return 'now' end
  if seconds < 3600 then return ('%dm'):format(math.floor(seconds / 60)) end
  if seconds < 86400 then return ('%dh'):format(math.floor(seconds / 3600)) end
  if seconds < 604800 then return ('%dd'):format(math.floor(seconds / 86400)) end
  return os.date('%Y-%m-%d', timestamp)
end

local function operation_parts(subject)
  local operation, detail = subject:match('^(.-):%s*(.*)$')
  if not operation then return 'update', subject end
  if operation == 'commit (amend)' then operation = 'amend'
  elseif operation:match('^commit') then operation = 'commit'
  elseif operation:match('^rebase') then operation = 'rebase'
  elseif operation:match('^reset') then operation = 'reset'
  elseif operation:match('^checkout') then operation = 'checkout'
  elseif operation:match('^cherry%-pick') then operation = 'cherry-pick' end
  if operation == 'checkout' then
    local from, to = detail:match('^moving from (.+) to (.+)$')
    if from and to then detail = from .. ' → ' .. to end
  elseif operation == 'reset' then
    detail = detail:gsub('^moving to ', '→ ')
  end
  return operation, detail
end

local function get_reflog_entries(bufnr)
  local work_tree = utils.get_buf_work_tree(bufnr)
  if not work_tree then return {}, 'Git work tree not found' end
  local result = run(work_tree, {
    'reflog', '--date=unix', '--format=%H%x09%h%x09%gd%x09%gs', '-n', '1000',
  })
  if result.code ~= 0 then return {}, vim.trim(result.stderr or 'git reflog failed') end

  local entries, counts = {}, {}
  for index, line in ipairs(vim.split(result.stdout or '', '\n', { plain = true, trimempty = true })) do
    local hash, short_hash, dated_selector, subject = line:match('^(%x+)\t(%x+)\t([^\t]+)\t(.*)$')
    local timestamp = dated_selector and tonumber(dated_selector:match('@%{(%d+)%}')) or nil
    if hash and timestamp then
      local operation, detail = operation_parts(subject)
      local entry = {
        hash = hash,
        short_hash = short_hash,
        selector = ('HEAD@{%d}'):format(index - 1),
        timestamp = timestamp,
        operation = operation,
        detail = detail,
      }
      table.insert(entries, entry)
      counts[hash] = (counts[hash] or 0) + 1
    end
  end
  for _, entry in ipairs(entries) do entry.same_count = counts[entry.hash] end
  return entries
end

local function render_entry(entry)
  local suffix = entry.same_count > 1 and ('  [same ×%d]'):format(entry.same_count) or ''
  return ('%-11s %10s  %-8s  %-12s %s%s'):format(
    entry.selector,
    age_label(entry.timestamp),
    entry.short_hash,
    entry.operation,
    entry.detail,
    suffix
  )
end

local function highlight_range(bufnr, row, line, text, start_at, group, priority)
  local start_col, end_col = line:find(text, start_at or 1, true)
  if not start_col then return nil end
  vim.api.nvim_buf_set_extmark(bufnr, static_ns, row - 1, start_col - 1, {
    end_col = end_col,
    hl_group = group,
    priority = priority or 100,
  })
  return end_col + 1
end

local function apply_static_highlights(bufnr, lines, entries)
  vim.api.nvim_buf_clear_namespace(bufnr, static_ns, 0, -1)
  for row, entry in ipairs(entries) do
    local line = lines[row]
    local next_col = highlight_range(bufnr, row, line, entry.selector, 1, 'Directory')
    next_col = highlight_range(bufnr, row, line, age_label(entry.timestamp), next_col, 'Comment')
    next_col = highlight_range(bufnr, row, line, entry.short_hash, next_col,
      entry.same_count > 1 and 'DiagnosticInfo' or 'String')
    local operation_group = ({
      reset = 'DiagnosticWarn',
      rebase = 'DiagnosticWarn',
      amend = 'GitSignsChange',
      checkout = 'Type',
      ['cherry-pick'] = 'GitSignsAdd',
    })[entry.operation] or 'Identifier'
    highlight_range(bufnr, row, line, entry.operation, next_col, operation_group)
    if entry.same_count > 1 then
      highlight_range(bufnr, row, line, ('[same ×%d]'):format(entry.same_count), 1, 'DiagnosticInfo')
    end
  end
end

local function entry_at(bufnr, row)
  return entries_by_buf[bufnr] and entries_by_buf[bufnr][row] or nil
end

local function highlight_linked_entries(bufnr)
  if not utils.is_valid_buf(bufnr) then return end
  vim.api.nvim_buf_clear_namespace(bufnr, linked_ns, 0, -1)
  local winid = vim.fn.bufwinid(bufnr)
  if winid == -1 then return end
  local entry = entry_at(bufnr, vim.api.nvim_win_get_cursor(winid)[1])
  if not entry or entry.same_count < 2 then return end
  for _, row in ipairs((rows_by_hash_by_buf[bufnr] or {})[entry.hash] or {}) do
    local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ''
    local start_col, end_col = line:find(entry.short_hash, 1, true)
    if start_col then
      vim.api.nvim_buf_set_extmark(bufnr, linked_ns, row - 1, start_col - 1, {
        end_col = end_col,
        hl_group = 'IncSearch',
        priority = 200,
      })
    end
  end
end

local function refresh_reflog_list(bufnr)
  if not utils.is_valid_buf(bufnr) then return end
  local entries, err = get_reflog_entries(bufnr)
  if err then vim.notify(err, vim.log.levels.ERROR); return end
  local lines, rows_by_hash = {}, {}
  for row, entry in ipairs(entries) do
    lines[row] = render_entry(entry)
    rows_by_hash[entry.hash] = rows_by_hash[entry.hash] or {}
    table.insert(rows_by_hash[entry.hash], row)
  end
  entries_by_buf[bufnr] = entries
  rows_by_hash_by_buf[bufnr] = rows_by_hash
  utils.with_buf_modifiable(bufnr, function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, #lines > 0 and lines or { 'No reflog entries' })
  end)
  apply_static_highlights(bufnr, lines, entries)
  highlight_linked_entries(bufnr)
end

local function open_reflog_list()
  local current_buf = vim.api.nvim_get_current_buf()
  local work_tree = utils.get_buf_work_tree(current_buf)
    or utils.get_work_tree({ bufnr = current_buf, notify = true })
  if not work_tree then return end
  vim.cmd('botright new')
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(bufnr, 'fugitive-reflog://' .. work_tree)
  utils.set_buf_work_tree(bufnr, work_tree)
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].bufhidden = 'wipe'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].filetype = 'fugitivereflog'
end

local function show_reflog_help()
  help.show('Reflog recovery actions', {
    'g?          show this help',
    '<CR>        inspect selected destination',
    ']s / [s     next / previous visit to same hash',
    'y           copy reflog selector (HEAD@{n})',
    '<C-y>       copy short hash',
    'B           create rescue branch at destination',
    '<Leader>R   reset --mixed to destination',
    'd           Diffview selected commit',
    'C           commit info float',
    '<C-p>       toggle commit preview',
    'R           reload reflog',
    'q           close buffer',
  })
end

local function reset_effect(work_tree, target_hash)
  local head = vim.trim(run(work_tree, { 'rev-parse', 'HEAD' }).stdout or '')
  if head == target_hash then return 'HEAD is already at this destination' end
  if run(work_tree, { 'merge-base', '--is-ancestor', target_hash, head }).code == 0 then
    local count = vim.trim(run(work_tree, { 'rev-list', '--count', target_hash .. '..' .. head }).stdout or '')
    return ('move HEAD back %s commit(s)'):format(count)
  end
  if run(work_tree, { 'merge-base', '--is-ancestor', head, target_hash }).code == 0 then
    local count = vim.trim(run(work_tree, { 'rev-list', '--count', head .. '..' .. target_hash }).stdout or '')
    return ('move HEAD forward %s commit(s)'):format(count)
  end
  local counts = vim.trim(run(work_tree, { 'rev-list', '--left-right', '--count', target_hash .. '...' .. head }).stdout or '')
  local target_only, current_only = counts:match('^(%d+)%s+(%d+)$')
  return target_only and ('switch histories: target +%s / current -%s commit(s)'):format(target_only, current_only)
    or 'move HEAD to a different history'
end

local function move_same_hash(bufnr, direction)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local entry = entry_at(bufnr, row)
  local rows = entry and (rows_by_hash_by_buf[bufnr] or {})[entry.hash] or nil
  if not rows or #rows < 2 then
    vim.notify('This destination appears only once in the reflog', vim.log.levels.INFO)
    return
  end
  for _ = 1, vim.v.count1 do
    local target
    if direction > 0 then
      for _, candidate in ipairs(rows) do if candidate > row then target = candidate; break end end
      row = target or rows[1]
    else
      for index = #rows, 1, -1 do if rows[index] < row then target = rows[index]; break end end
      row = target or rows[#rows]
    end
  end
  vim.api.nvim_win_set_cursor(0, { row, 0 })
end

function M.setup(group)
  vim.api.nvim_create_user_command('Greflog', open_reflog_list, {
    bang = false,
    desc = 'Open recovery-oriented Git reflog',
  })

  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'fugitivereflog',
    callback = function(ev)
      local b = ev.buf
      local buf_group = vim.api.nvim_create_augroup('fugitive_reflog_buf_' .. b, { clear = true })
      vim.opt_local.conceallevel = 0
      vim.opt_local.list = false
      vim.opt_local.number = false
      vim.opt_local.relativenumber = false
      vim.opt_local.cursorline = true
      refresh_reflog_list(b)

      vim.keymap.set('n', 'g?', show_reflog_help,
        { buffer = b, nowait = true, silent = true, desc = 'Help' })
      vim.keymap.set('n', ']s', function() move_same_hash(b, 1) end,
        { buffer = b, nowait = true, silent = true, desc = 'Next visit to same reflog destination' })
      vim.keymap.set('n', '[s', function() move_same_hash(b, -1) end,
        { buffer = b, nowait = true, silent = true, desc = 'Previous visit to same reflog destination' })

      vim.keymap.set('n', 'd', function()
        local entry = entry_at(b, vim.fn.line('.'))
        if entry then vim.schedule(function() vim.cmd('DiffviewOpen ' .. entry.hash .. '^..' .. entry.hash) end) end
      end, { buffer = b, nowait = true, silent = true, desc = 'Diffview commit' })

      vim.keymap.set('n', 'C', function()
        local entry = entry_at(b, vim.fn.line('.'))
        if entry then commands.show_commit_info_float(entry.hash, true, true) end
      end, { buffer = b, nowait = true, silent = true, desc = 'Show commit info in float' })

      vim.keymap.set('n', 'y', function()
        local entry = entry_at(b, vim.fn.line('.'))
        if not entry then return end
        vim.fn.setreg('+', entry.selector)
        vim.fn.setreg('"', entry.selector)
        vim.notify('Copied: ' .. entry.selector, vim.log.levels.INFO)
      end, { buffer = b, nowait = true, silent = true, desc = 'Copy reflog selector' })

      vim.keymap.set('n', '<C-y>', function()
        local entry = entry_at(b, vim.fn.line('.'))
        if not entry then return end
        vim.fn.setreg('+', entry.short_hash)
        vim.fn.setreg('"', entry.short_hash)
        vim.notify('Copied: ' .. entry.short_hash, vim.log.levels.INFO)
      end, { buffer = b, nowait = true, silent = true, desc = 'Copy short hash' })

      vim.keymap.set('n', '<C-p>', function()
        local entry = entry_at(b, vim.fn.line('.'))
        commands.toggle_preview(entry and entry.hash or nil)
      end, { buffer = b, silent = true, desc = 'Toggle commit preview' })

      vim.api.nvim_create_autocmd('CursorMoved', {
        group = buf_group,
        buffer = b,
        callback = function()
          highlight_linked_entries(b)
          if commands.is_preview_open() then
            local entry = entry_at(b, vim.fn.line('.'))
            commands.schedule_update_preview(entry and entry.hash or nil)
          end
        end,
      })

      vim.keymap.set('n', 'B', function()
        local entry = entry_at(b, vim.fn.line('.'))
        local work_tree = utils.get_buf_work_tree(b)
        if not entry or not work_tree then return end
        local default = ('rescue/%s-%s'):format(os.date('%Y%m%d-%H%M', entry.timestamp), entry.short_hash)
        vim.ui.input({ prompt = 'Rescue branch name: ', default = default }, function(name)
          name = name and vim.trim(name) or ''
          if name == '' then return end
          local valid = run(work_tree, { 'check-ref-format', '--branch', name })
          if valid.code ~= 0 then vim.notify('Invalid branch name: ' .. name, vim.log.levels.ERROR); return end
          local created = run(work_tree, { 'branch', name, entry.hash })
          if created.code ~= 0 then
            vim.notify(vim.trim(created.stderr or 'Failed to create rescue branch'), vim.log.levels.ERROR)
            return
          end
          vim.notify(('Created %s at %s'):format(name, entry.short_hash), vim.log.levels.INFO)
          utils.fire_fugitive_changed({ work_tree = work_tree })
        end)
      end, { buffer = b, nowait = true, silent = true, desc = 'Create rescue branch' })

      vim.keymap.set('n', '<Leader>R', function()
        local entry = entry_at(b, vim.fn.line('.'))
        local work_tree = utils.get_buf_work_tree(b)
        if not entry or not work_tree then return end
        local branch_result = run(work_tree, { 'branch', '--show-current' })
        local branch = vim.trim(branch_result.stdout or '')
        if branch == '' then branch = 'detached HEAD' end
        local dirty = run(work_tree, { 'status', '--porcelain' })
        local dirty_note = vim.trim(dirty.stdout or '') ~= '' and '\nWorking tree changes will be kept; index will be reset.' or ''
        local message = table.concat({
          ('Reset %s to %s (%s)?'):format(branch, entry.selector, entry.short_hash),
          'Effect: ' .. reset_effect(work_tree, entry.hash),
          'Mode: git reset --mixed' .. dirty_note,
        }, '\n')
        if vim.fn.confirm(message, '&Reset\n&Cancel', 2) ~= 1 then return end
        local result = run(work_tree, { 'reset', '--mixed', entry.hash })
        if result.code ~= 0 then
          vim.notify(vim.trim(result.stderr or 'Reset failed'), vim.log.levels.ERROR)
          return
        end
        vim.notify('Reset to ' .. entry.selector .. ' (' .. entry.short_hash .. ')', vim.log.levels.INFO)
        utils.fire_fugitive_changed({ work_tree = work_tree })
        refresh_reflog_list(b)
      end, { buffer = b, nowait = true, silent = true, desc = 'Reset --mixed to destination' })

      vim.keymap.set('n', 'R', function() refresh_reflog_list(b) end,
        { buffer = b, nowait = true, silent = true, desc = 'Reload reflog' })
      vim.keymap.set('n', '<CR>', function()
        local entry = entry_at(b, vim.fn.line('.'))
        if entry then vim.cmd('Gedit ' .. entry.hash) end
      end, { buffer = b, nowait = true, silent = true, desc = 'Inspect reflog destination' })
      vim.keymap.set('n', 'q', function()
        commands.close_commit_info_float()
        require('utilities').smart_close()
      end, { buffer = b, nowait = true, silent = true, desc = 'Close reflog' })

      vim.api.nvim_create_autocmd('BufUnload', {
        group = buf_group,
        buffer = b,
        callback = function()
          entries_by_buf[b] = nil
          rows_by_hash_by_buf[b] = nil
          commands.close_preview()
          commands.close_commit_info_float()
        end,
      })
      utils.setup_repo_refresh(buf_group, b, function(bufnr) refresh_reflog_list(bufnr) end,
        { visible_only = true })
    end,
  })
end

return M
