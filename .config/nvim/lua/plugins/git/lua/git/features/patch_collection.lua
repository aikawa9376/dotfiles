-- A tab owns one immutable commit and a multi-file selection; no global basket.
local M = {}
local model_api = require('git.features.commit_model')
local commit = require('git.features.commit')
local async = require('git.features.async')
local syntax = require('git.features.syntax_highlight')
local sessions = {}
local function notify(message) vim.notify(message, vim.log.levels.WARN) end
local function active(s)
  return not s.closed and vim.api.nvim_tabpage_is_valid(s.tab)
    and vim.api.nvim_buf_is_loaded(s.right) and vim.api.nvim_buf_is_loaded(s.left)
end
local function lines(text) return vim.split(text, '\n', { plain = true }) end
local function message(s)
  if not vim.api.nvim_buf_is_valid(s.right) then return s.message end
  local all = vim.api.nvim_buf_get_lines(s.right, 0, -1, false)
  local boundary
  for i, line in ipairs(all) do if line == '# --- Collected patch (read-only) ---' then boundary = i; break end end
  if not boundary then return nil, 'Keep the collected-patch separator intact' end
  return vim.list_slice(all, 4, boundary - 2)
end

function M.patch(s)
  local result = {}
  for _, entry in ipairs(s.model.entries) do
    local selected = s.selected[entry.path]
    if selected then
      local original = entry.patch
      if selected.whole then vim.list_extend(result, original)
      else
        local header, chunks = nil, {}
        for row, line in ipairs(original) do
          if line:match('^@@ ') then
            local last = row + 1
            while last <= #original and not original[last]:match('^@@ ') do last = last + 1 end
            local partial = require('git.features.commit_patch').selection(original, row,
              row + 1, last - 1, selected.lines)
            if partial then
              local start
              for at, value in ipairs(partial) do if value:match('^@@ ') then start = at; break end end
              if not header then header = vim.list_slice(partial, 1, start - 1) end
              vim.list_extend(chunks, vim.list_slice(partial, start))
            end
          end
        end
        if header then vim.list_extend(result, header); vim.list_extend(result, chunks) end
      end
    end
  end
  return result
end

local function render(s)
  if not active(s) then return end
  local draft, err = message(s)
  if not draft then notify(err); return end
  s.message = draft
  local patch = M.patch(s)
  local content = { '# Split from ' .. s.model.hash:sub(1, 12),
    '# Edit message below; <Space> collects, c splits, r clears, q closes', '' }
  vim.list_extend(content, #draft > 0 and draft or { '' })
  vim.list_extend(content, { '', '# --- Collected patch (read-only) ---' })
  if #patch == 0 then content[#content + 1] = '# No changes selected'
  else vim.list_extend(content, patch) end
  vim.api.nvim_buf_set_lines(s.right, 0, -1, false, content)
  vim.bo[s.right].modified = false
  syntax.refresh(s.right)
  require('git.features.panel_highlight').patch(s)
end

local function close(s)
  if s.closed then return end
  s.closed = true
  sessions[s.tab] = nil
  for _, task in pairs(s.tasks) do task.cancel() end
  s.tasks, s.selected = {}, {}
  if vim.api.nvim_tabpage_is_valid(s.tab) and #vim.api.nvim_list_tabpages() > 1 then
    vim.api.nvim_set_current_tabpage(s.tab)
    vim.cmd('tabclose!')
  end
  for _, b in ipairs({ s.left, s.right }) do
    if vim.api.nvim_buf_is_valid(b) then pcall(vim.api.nvim_buf_delete, b, { force = true }) end
  end
  if vim.api.nvim_win_is_valid(s.origin) then vim.api.nvim_set_current_win(s.origin) end
end

function M.collect(s, first, last)
  if not active(s) or s.busy then return end
  local entry, info = commit.entry_at(s.left, first)
  if not entry then notify('Select a file, hunk or changed lines in the left panel'); return end
  local end_entry, end_info = commit.entry_at(s.left, last or first)
  if end_entry ~= entry then notify('Select lines within one file'); return end
  local task
  task = async.run(s.root, function()
    local patch, err = model_api.patch(s.model, entry)
    if not patch then error(err, 0) end
    return patch
  end, function(ok, patch)
    if task then s.tasks[task] = nil end
    if not active(s) then return end
    if not ok then notify(patch); return end
    local selection = s.selected[entry.path]
    if not info.patch_row then
      if selection and selection.whole then s.selected[entry.path] = nil
      else s.selected[entry.path] = { whole = true } end
    else
      if entry.binary then notify('Binary files can only be collected as a whole'); return end
      local start = info.patch_row
      while start > 1 and not patch[start]:match('^@@ ') do start = start - 1 end
      if not patch[start]:match('^@@ ') then notify('Select text changes, or collect the whole file'); return end
      local finish = start + 1
      while finish <= #patch and not patch[finish]:match('^@@ ') do finish = finish + 1 end
      local a, b = last and info.patch_row or start + 1, last and end_info.patch_row or finish - 1
      if not b or b >= finish or a < start then notify('Select changed lines within one hunk'); return end
      selection = selection or { lines = {} }
      if selection.whole then
        selection = { lines = {} }
        for i, line in ipairs(patch) do if line:match('^[+-]') and not line:match('^[+-][+-][+-]') then selection.lines[i] = true end end
      end
      local indices, all = {}, true
      for row = a, b do
        if patch[row]:match('^[+-]') then indices[#indices + 1] = row; all = all and selection.lines[row] == true end
      end
      if #indices == 0 then notify('No changed lines selected'); return end
      for _, row in ipairs(indices) do selection.lines[row] = not all or nil end
      s.selected[entry.path] = next(selection.lines) and selection or nil
    end
    render(s)
  end)
  if task and not task.completed then s.tasks[task] = task end
end

function M.split(s)
  if not active(s) or s.busy then return end
  local draft, err = message(s)
  if not draft then notify(err); return end
  if vim.trim(table.concat(draft, '\n')) == '' then notify('Enter the new commit message in the right panel'); return end
  local patch = M.patch(s)
  if #patch == 0 then notify('Collect changes before splitting'); return end
  -- The preview must still correspond to the collected selection.
  local all = vim.api.nvim_buf_get_lines(s.right, 0, -1, false)
  local boundary
  for i, line in ipairs(all) do if line == '# --- Collected patch (read-only) ---' then boundary = i end end
  if not vim.deep_equal(vim.list_slice(all, boundary + 1), patch) then
    notify('Collected diff was edited; press R to restore the preview'); return
  end
  vim.ui.select({ 'Split into new commit after source', 'Cancel' }, { prompt = 'Rewrite ' .. s.model.hash:sub(1, 12) .. ' and descendants?' }, function(choice)
    if not choice or choice == 'Cancel' or not active(s) or s.busy then return end
    s.busy = true
    local task, failure = async.run(s.root, function()
      local target, warning = require('git.features.commit_rewrite').apply(s.root, s.model.hash,
        { patch = patch, reverse = true, split = true, message = draft, expected_head = s.head })
      if not target then error(warning, 0) end
      return target, warning
    end, function(ok, target, warning)
      s.busy = false
      if not active(s) then
        if not ok or warning then notify(warning or target) end
        return
      end
      if not ok then notify(target); return end
      if warning then notify(warning) end
      close(s)
      commit.open({ work_tree = s.root, revision = target, tab = true })
    end, { mutation = true })
    if not task then s.busy = false; notify(failure) end
  end)
end

function M.open(ctx)
  local root = ctx.work_tree
  if not root then return end
  local origin = ctx.source_win or vim.api.nvim_get_current_win()
  local existing = sessions[vim.api.nvim_get_current_tabpage()]
  if existing and active(existing) then vim.api.nvim_set_current_win(existing.right_win); return existing end
  local revision = ctx.commit or 'HEAD'
  return async.run(root, function()
    local model, err = model_api.load(root, revision)
    if not model then error(err, 0) end
    return model, vim.trim(assert(model_api.git(root, { 'rev-parse', 'HEAD' })))
  end, function(ok, model, head)
    if not ok then notify(model); return end
    if not vim.api.nvim_win_is_valid(origin) then return end
    vim.api.nvim_set_current_win(origin)
    vim.cmd('tabnew')
    local tab = vim.api.nvim_get_current_tabpage()
    local placeholder = vim.api.nvim_get_current_buf()
    local left = commit.open({ work_tree = root, model = model, expected_head = head, new = true })
    vim.bo[left].modifiable = false
    vim.bo[left].bufhidden = 'hide'
    vim.cmd('belowright vsplit')
    local right_win = vim.api.nvim_get_current_win()
    local right = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(right_win, right)
    vim.bo[right].buftype, vim.bo[right].bufhidden, vim.bo[right].swapfile = 'nofile', 'wipe', false
    vim.bo[right].filetype, vim.bo[right].syntax = 'gitpatchcollection', 'git'
    require('git.utils').set_buf_work_tree(right, root)
    vim.b[right].fugitive_commit = model.hash
    vim.wo[right_win].wrap = false
    local s = { root = root, model = model, head = head, left = left, right = right,
      right_win = right_win, tab = tab, origin = origin, selected = {}, tasks = {}, message = { '' } }
    sessions[tab] = s
    vim.api.nvim_buf_set_lines(right, 0, -1, false, { '# Split from ' .. model.hash:sub(1, 12),
      '# Edit message below; <Space> collects, c splits, r clears, q closes', '', '', '', '# --- Collected patch (read-only) ---' })
    syntax.attach(right, { first_line = function()
      for row, line in ipairs(vim.api.nvim_buf_get_lines(right, 0, -1, false)) do
        if line == '# --- Collected patch (read-only) ---' then return row + 1 end
      end
      return vim.api.nvim_buf_line_count(right) + 1
    end })
    render(s)
    local function expand(mode)
      local entry = commit.entry_at(left, vim.fn.line('.'))
      if not entry then return end
      local expanded = commit.navigation(left, vim.fn.line('.')).expanded[entry.path]
      if mode == 'hide' or (mode == 'toggle' and expanded) then
        commit.expand_file(left, entry.path, false)
        require('git.features.panel_highlight').patch(s)
        vim.bo[left].modifiable, vim.bo[left].bufhidden = false, 'wipe'
        return
      end
      local task
      task = async.run(root, function()
        local patch, err = model_api.patch(model, entry)
        if not patch then error(err, 0) end
      end, function(success, err)
        if task then s.tasks[task] = nil end
        if active(s) then
          if success then commit.expand_file(left, entry.path); require('git.features.panel_highlight').patch(s); vim.bo[left].modifiable = false; vim.bo[left].bufhidden = 'wipe'
          else notify(err) end
        end
      end)
      if task and not task.completed then s.tasks[task] = task end
    end
    for _, b in ipairs({ left, right }) do
      vim.keymap.set('n', 'q', function() close(s) end, { buffer = b, silent = true })
      vim.keymap.set('n', '<Tab>', function()
        local target = vim.api.nvim_get_current_buf() == right and vim.fn.bufwinid(left) or right_win
        if vim.api.nvim_win_is_valid(target) then vim.api.nvim_set_current_win(target) end
      end, { buffer = b, silent = true })
    end
    for key, mode in pairs({ ['<CR>'] = 'toggle', o = 'toggle', ['='] = 'toggle', ['>'] = 'show', ['<'] = 'hide' }) do
      local chosen = mode
      vim.keymap.set('n', key, function() expand(chosen) end,
        { buffer = left, silent = true, desc = chosen == 'toggle' and 'Toggle selected diff'
          or chosen == 'show' and 'Expand selected diff' or 'Collapse selected diff' })
    end
    vim.keymap.set('n', '<Space>', function() M.collect(s, vim.fn.line('.')) end, { buffer = left, silent = true })
    vim.keymap.set('x', '<Space>', function()
      local a, b = math.min(vim.fn.line('v'), vim.fn.line('.')), math.max(vim.fn.line('v'), vim.fn.line('.'))
      vim.cmd('normal! \27'); M.collect(s, a, b)
    end, { buffer = left, silent = true })
    vim.keymap.set('n', 'c', function() M.split(s) end, { buffer = right, silent = true })
    vim.keymap.set('n', 'r', function() s.selected = {}; render(s) end, { buffer = right, silent = true })
    vim.keymap.set('n', 'R', function() render(s) end, { buffer = right, silent = true })
    vim.bo[left].bufhidden = 'wipe'
    local group = vim.api.nvim_create_augroup('GitPatchCollection' .. right, { clear = true })
    for _, b in ipairs({ left, right }) do
      vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, { group = group, buffer = b, callback = function()
        if active(s) then require('git.features.panel_highlight').patch(s) end
      end })
    end
    local function unload()
        if not s.closed then
          s.closed = true; sessions[tab] = nil
          for _, task in pairs(s.tasks) do task.cancel() end
          s.tasks, s.selected = {}, {}
          vim.schedule(function()
            for _, b in ipairs({ left, right }) do
              if vim.api.nvim_buf_is_valid(b) then pcall(vim.api.nvim_buf_delete, b, { force = true }) end
            end
          end)
        end
        pcall(vim.api.nvim_del_augroup_by_id, group)
    end
    for _, b in ipairs({ left, right }) do
      vim.api.nvim_create_autocmd({ 'BufUnload', 'BufWipeout' }, { group = group, buffer = b, once = true,
        callback = unload })
    end
    if vim.api.nvim_buf_is_valid(placeholder) then pcall(vim.api.nvim_buf_delete, placeholder, { force = true }) end
    vim.api.nvim_set_current_win(vim.fn.bufwinid(left))
    vim.cmd('wincmd =')
  end)
end
function M.session(tab) return sessions[tab or vim.api.nvim_get_current_tabpage()] end
return M
