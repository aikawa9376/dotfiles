-- Editable plans own drafts; Git history changes only after explicit execution.
local M = {}
local model = require('git.features.rebase_plan_model')
local todo = require('git.features.rebase_todo')
local async = require('git.features.async')
local utils = require('git.utils')
local marks, sessions = {}, {}
local ns = vim.api.nvim_create_namespace('git_rebase_plan')
local mark_ns = vim.api.nvim_create_namespace('git_rebase_base')
local function warn(err) vim.notify(err, vim.log.levels.WARN) end
local function lines(buf) return vim.api.nvim_buf_get_lines(buf, 0, -1, false) end
local function header(state)
  local m = state.model
  return {
    '# Rebase plan: ' .. (m.branch ~= '' and m.branch:gsub('^refs/heads/', '') or 'detached HEAD'),
    '# Old base (excluded): ' .. (m.base or '--root'),
    '# New base: ' .. (m.onto or '--root'),
    '# dd/p: move | i: subject | Enter: preview | gk: message | ca: action | cb/cx: break/exec',
    '# :write / Ctrl-s: execute | Ctrl-a/x: cycle action | mb/mo: bases | g?: help | q: close',
    '',
  }
end
local function render(state, rows)
  local text = header(state)
  for _, row in ipairs(rows or state.model.entries) do
    text[#text + 1] = row.control and (row.action .. (row.command and (' ' .. row.command) or ''))
      or ((row.action or 'pick') .. ' ' .. row.hash:sub(1, 12) .. ' ' .. row.subject)
  end
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, text)
end
local function sequence(state)
  return vim.api.nvim_buf_call(state.buf, function() return vim.fn.undotree().seq_cur end)
end
local function remember(state)
  -- Source entries are immutable; undo snapshots share them instead of copying
  -- every commit message for each typed character in a large plan.
  state.snapshots[sequence(state)] = { model = state.model, messages = vim.deepcopy(state.messages) }
end
local function sync(state)
  local saved = state.snapshots[sequence(state)]
  if saved then
    local previous = state.model.base
    state.model, state.messages = saved.model, vim.deepcopy(saved.messages)
    if previous ~= state.model.base then
      marks[state.model.root] = state.model.base or nil
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do M.paint_mark(buf) end
    end
  else remember(state) end
end
local function paint(state)
  if not vim.api.nvim_buf_is_valid(state.buf) then return end
  sync(state)
  require('git.features.panel_highlight').rebase(state.buf)
  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  if state.paused then
    vim.api.nvim_buf_set_extmark(state.buf, ns, 5, 0, { virt_text = {
      { 'Rebase paused — cC: continue | cS: skip | cA: abort | cT: edit live todo', 'DiagnosticWarn' } }, virt_text_pos = 'eol' })
  end
  for row, line in ipairs(lines(state.buf)) do
    local entry = model.entry(state.model, line)
    if entry and not entry.control then
      local message = state.messages[entry.hash] or entry.original.message
      if message:match('\n.*%S') then
        vim.api.nvim_buf_set_extmark(state.buf, ns, row - 1, #line, {
          virt_text = { { ' 󰍡', 'Comment' } }, virt_text_pos = 'eol' })
      end
    end
  end
end
local function parsed(state)
  sync(state)
  local text, expected = lines(state.buf), header(state)
  for i = 1, 3 do
    if text[i] ~= expected[i] then return nil, 'Plan headers changed; use mb/mo for bases or undo the header edit' end
  end
  return model.parse(state.model, text, state.messages)
end

function M.complete_refs(lead)
  local root = utils.get_work_tree({ bufnr = vim.api.nvim_get_current_buf() })
  local choices = { 'HEAD', '--root' }
  if root then
    local refs = require('git.features.commit_model').git(root, { 'for-each-ref', '--format=%(refname:short)' })
    if refs then vim.list_extend(choices, vim.split(refs, '\n', { trimempty = true })) end
  end
  return vim.tbl_filter(function(ref) return ref:sub(1, #lead) == lead end, choices)
end

function M.mark(root, revision)
  if not root or not revision then warn('Choose a commit to mark as old base'); return end
  return async.run(root, function()
    local tx, err = require('git.features.history_rewrite').prepare(root, { revision })
    if not tx then error(err, 0) end
    return tx.commits[1]
  end, function(ok, hash)
    if not ok then warn(hash); return end
    if marks[root] == hash then M.clear_mark(root); return end
    marks[root] = hash
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do M.paint_mark(buf) end
    vim.notify('Old rebase base marked: ' .. hash:sub(1, 12) .. ' (excluded)', vim.log.levels.INFO)
  end)
end

function M.paint_mark(buf)
  if not vim.api.nvim_buf_is_loaded(buf) then return end
  local ft = vim.bo[buf].filetype
  if not vim.tbl_contains({ 'fugitivestatus', 'fugitivelog', 'fugitivereflog', 'fugitivecommit' }, ft) then return end
  vim.api.nvim_buf_clear_namespace(buf, mark_ns, 0, -1)
  local hash = marks[utils.get_buf_work_tree(buf)]
  if not hash then return end
  for row, line in ipairs(lines(buf)) do
    local short = line:match('^(%x%x%x%x%x%x%x+)') or line:match('^commit (%x+)')
    if short and hash:sub(1, #short) == short then
      vim.api.nvim_buf_set_extmark(buf, mark_ns, row - 1, 0, {
        virt_text = { { ' [rebase base]', 'Special' } }, virt_text_pos = 'eol',
        sign_text = 'B', sign_hl_group = 'Special' })
    end
  end
end

function M.clear_mark(root)
  if not root then return end
  marks[root] = nil
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do M.paint_mark(buf) end
  vim.notify('Old rebase base cleared', vim.log.levels.INFO)
end

vim.api.nvim_create_autocmd({ 'BufEnter', 'TextChanged' }, {
  group = vim.api.nvim_create_augroup('GitRebaseBaseMarks', { clear = true }),
  callback = function(ev) M.paint_mark(ev.buf) end,
})

function M.message(buf)
  local state = sessions[buf]
  if not state or state.running or state.paused then return end
  if state.float and vim.api.nvim_buf_is_valid(state.float) then
    local win = vim.fn.bufwinid(state.float)
    if win ~= -1 then vim.api.nvim_set_current_win(win); return end
  end
  sync(state)
  local entry, err = model.entry(state.model, vim.api.nvim_get_current_line())
  if not entry or entry.control then warn(err or 'Choose a commit row'); return end
  local message = state.messages[entry.hash] or entry.original.message
  message = entry.subject .. (message:match('(\n.*)$') or '')
  local original_line = vim.api.nvim_get_current_line()
  state.float = todo.message_float(message, 'Plan message ' .. entry.hash:sub(1, 12), function(text)
    if not sessions[buf] or state.running then return nil, 'The plan is unavailable' end
    local found
    for row, line in ipairs(lines(buf)) do
      local value = model.entry(state.model, line)
      if value and value.hash == entry.hash then
        if found then return nil, 'Duplicate commit; fix the plan first' end
        if line ~= original_line then return nil, 'This commit row changed while the message was open; reopen it' end
        found = row
      end
    end
    if not found then return nil, 'This commit was removed from the plan' end
    if entry.action == 'fixup' or entry.action == 'squash' or entry.action == 'drop' then
      return nil, 'Choose pick/reword before editing this message'
    end
    sync(state)
    state.messages[entry.hash] = text
    vim.api.nvim_buf_call(buf, function()
      vim.api.nvim_win_set_cursor(0, { found, 0 })
      vim.api.nvim_buf_set_lines(buf, found - 1, found, false, {
        'reword ' .. entry.hash:sub(1, 12) .. ' ' .. text:match('^[^\n]*') })
    end)
    remember(state)
    paint(state)
    return true
  end, buf)
end

function M.execute(buf)
  local state = sessions[buf]
  if not state or state.running then return end
  if state.paused then return require('git.features.rebase_plan_session').open(state.model.root, 'continue') end
  if state.float and vim.api.nvim_buf_is_valid(state.float) and vim.bo[state.float].modified then
    warn('Save or discard the open message draft before executing'); return
  end
  vim.cmd('stopinsert')
  local rows, err = parsed(state)
  if not rows then warn(err); return end
  local dropped, changed, controls = 0, 0, 0
  for _, row in ipairs(rows) do
    if row.control or row.action == 'edit' then controls = controls + 1 end
    if row.action == 'drop' then dropped = dropped + 1 end
    if row.action == 'reword' then changed = changed + 1 end
  end
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local m = state.model
  vim.ui.select({ 'Execute rebase plan', 'Cancel' }, {
    prompt = ('Rebase %d commits (%d drop, %d reword, %d stop/exec), %s → %s?'):format(#m.entries, dropped, changed, controls,
      m.base and m.base:sub(1, 12) or '--root', m.onto and m.onto:sub(1, 12) or '--root'),
  }, function(choice)
    if choice ~= 'Execute rebase plan' then return end
    if sessions[buf] ~= state or state.running or vim.api.nvim_buf_get_changedtick(buf) ~= tick then
      warn('Plan changed; review and execute again'); return
    end
    state.running = true
    vim.bo[buf].modifiable = false
    local job, failure = async.run(m.root, function() return model.execute(m, rows) end,
      function(ok, target, warning, did_change, paused)
        state.running = false
        if not ok or not target then
          if vim.api.nvim_buf_is_valid(buf) then vim.bo[buf].modifiable = true end
          warn(ok and warning or target); return
        end
        if warning then warn(warning) end
        if paused then
          if sessions[buf] == state then state.paused = true; vim.bo[buf].modified = false; paint(state) end
          return
        end
        if sessions[buf] == state then
          vim.bo[buf].modified = false
          vim.api.nvim_buf_delete(buf, { force = true })
        end
        vim.notify(did_change == false and 'Rebase plan unchanged' or ('Rebase complete: ' .. target:sub(1, 12)), vim.log.levels.INFO)
      end, { mutation = true })
    if not job then state.running = false; vim.bo[buf].modifiable = true; warn(failure) end
  end)
end

local function base_from_row(state)
  if state.running or state.paused then return end
  sync(state)
  local entry, err = model.entry(state.model, vim.api.nvim_get_current_line())
  if not entry or entry.control then warn(err or 'Choose a commit row'); return end
  local rows, failure = parsed(state)
  if not rows then warn(failure); return end
  local index
  for i, value in ipairs(state.model.entries) do if value.hash == entry.hash then index = i end end
  if index == #state.model.entries then warn('No commits after this base'); return end
  local entries, by_hash = {}, {}
  for i = index + 1, #state.model.entries do
    local value = state.model.entries[i]; entries[#entries + 1], by_hash[value.hash] = value, value
  end
  local kept = vim.tbl_filter(function(row) return row.control or by_hash[row.hash] ~= nil end, rows)
  state.model = vim.tbl_extend('force', state.model, { base = entry.hash, entries = entries, by_hash = by_hash,
    onto = state.model.onto == state.model.base and entry.hash or state.model.onto })
  state.model.prefixes = nil
  marks[state.model.root] = entry.hash
  render(state, kept); remember(state); paint(state)
end

function M.open(ctx)
  ctx = ctx or {}
  local root = ctx.work_tree or utils.get_work_tree({ bufnr = vim.api.nvim_get_current_buf(), notify = true })
  if not root then return end
  local job
  job = async.run(root, function()
    return model.load(root, { base = ctx.base or marks[root], onto = ctx.onto, commit = ctx.commit })
  end, function(ok, m)
    if not ok then warn(m); return end
    local buf = vim.api.nvim_create_buf(true, false)
    local state = { model = m, buf = buf, messages = {}, snapshots = {} }; sessions[buf] = state
    vim.api.nvim_buf_set_name(buf, 'git-rebase-plan://' .. root .. '//' .. buf)
    vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = 'acwrite', 'hide', false
    vim.bo[buf].undofile = false
    vim.bo[buf].filetype, vim.bo[buf].syntax = 'gitrebaseplan', 'gitrebase'
    utils.set_buf_work_tree(buf, root)
    utils.open_panel_split(); vim.api.nvim_win_set_buf(0, buf)
    vim.wo.wrap, vim.wo.cursorline = false, true
    render(state); remember(state); paint(state); vim.bo[buf].modified = false
    vim.api.nvim_win_set_cursor(0, { 7, 0 })
    todo.attach(buf, { plan = true, show_message = function() M.message(buf) end })
    vim.keymap.set({ 'n', 'i' }, '<C-s>', function() M.execute(buf) end, { buffer = buf, silent = true })
    vim.keymap.set('n', 'mb', function() base_from_row(state) end, { buffer = buf, silent = true, desc = 'Mark old base (excluded)' })
    vim.keymap.set('n', 'mo', function()
      if state.running or state.paused then return end
      vim.ui.input({ prompt = 'New rebase base (branch or revision): ' }, function(ref)
        if not ref or ref == '' or sessions[buf] ~= state or state.running or state.paused then return end
        local tick = vim.api.nvim_buf_get_changedtick(buf)
        async.run(root, function()
          local out, err = require('git.features.commit_model').git(root, { 'rev-parse', '--verify', '--end-of-options', ref .. '^{commit}' })
          if not out then error(err, 0) end
          return vim.trim(out)
        end, function(success, hash)
          if not success then warn(hash); return end
          if sessions[buf] ~= state or state.running or vim.api.nvim_buf_get_changedtick(buf) ~= tick then
            warn('Plan changed; choose the new base again'); return
          end
          sync(state)
          state.model = vim.tbl_extend('force', state.model, { onto = hash })
          vim.api.nvim_buf_set_lines(buf, 2, 3, false, { header(state)[3] })
          remember(state)
        end)
      end)
    end, { buffer = buf, silent = true, desc = 'Choose new base' })
    for key, action in pairs({ cC = 'continue', cS = 'skip', cA = 'abort' }) do
      vim.keymap.set('n', key, function() require('git.features.rebase_plan_session').open(root, action) end,
        { buffer = buf, desc = 'Rebase ' .. action })
    end
    vim.keymap.set('n', 'cT', function()
      require('git.commands').git({ args = 'rebase --edit-todo', bufnr = buf })
    end, { buffer = buf, desc = 'Edit live rebase todo' })
    vim.keymap.set('n', 'g?', function()
      todo.message_float(table.concat({ 'Rebase plan', '',
        'Old base is excluded; only its descendants through the captured HEAD are replayed.',
        'dd then p/P moves rows; i/A edits subjects; u undoes buffer edits.',
        'gk edits the full message (including its body); :write in the float saves to the plan.',
        'Enter previews the original commit; ca chooses an action.',
        'cp/cr/ce/cs/cf/cd: pick/reword/edit/squash/fixup/drop.',
        'Ctrl-a/Ctrl-x cycles these actions with dial.nvim.',
        'cb/cx inserts break/exec after this row. Exec runs a shell command.',
        'Paused plan: cC continues, cS skips, cA aborts, cT edits the live todo.',
        'Saved WIP stays in stash until completion/abort, including across editor restarts.',
        'Ctrl-x Ctrl-u completes the action at the beginning of a row.',
        'mb marks this original commit as old base; mo chooses a new base.',
        'Deleted rows are drops, shown in the execution confirmation.',
        'Only :write or Ctrl-s executes. Closing the plan leaves Git unchanged.',
      }, '\n'), 'Rebase plan help', nil, buf)
    end, { buffer = buf, silent = true })
    vim.keymap.set('n', '<CR>', function()
      sync(state)
      local entry, err = model.entry(state.model, vim.api.nvim_get_current_line())
      if not entry or entry.control then warn(err or 'Choose a commit row'); return end
      require('git.features.commit').open({ work_tree = root, revision = entry.hash, tab = true })
    end, { buffer = buf, silent = true, desc = 'Inspect original commit' })
    vim.keymap.set('n', 'q', function()
      local dirty = vim.bo[buf].modified or (state.float and vim.api.nvim_buf_is_valid(state.float) and vim.bo[state.float].modified)
      if dirty and vim.fn.confirm('Discard this rebase plan?', '&Discard\n&Cancel', 2) ~= 1 then return end
      vim.api.nvim_buf_delete(buf, { force = true })
    end, { buffer = buf, silent = true })
    vim.api.nvim_create_autocmd('BufWriteCmd', { buffer = buf, callback = function(ev)
      if ev.match ~= vim.api.nvim_buf_get_name(buf) then warn('Write the plan itself to execute; alternate write names are unsupported'); return end
      M.execute(buf)
    end })
    vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, { buffer = buf, callback = function() paint(state) end })
    vim.api.nvim_create_autocmd({ 'BufUnload', 'BufWipeout' }, { buffer = buf, once = true, callback = function() sessions[buf] = nil end })
    if ctx.on_open then ctx.on_open(buf) end
  end)
  return job
end

function M.resume_result(root, paused)
  for buf, state in pairs(sessions) do
    if state.model.root == root and state.paused and vim.api.nvim_buf_is_valid(buf) then
      if paused then paint(state) else vim.bo[buf].modified = false; vim.api.nvim_buf_delete(buf, { force = true }) end
    end
  end
end

return M
