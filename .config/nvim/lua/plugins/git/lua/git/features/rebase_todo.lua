-- Editing helpers shared by a draft plan and Git's live rebase todo buffer.
local M = {}
local actions = { pick = 'p', reword = 'r', squash = 's', fixup = 'f', drop = 'd', edit = 'e' }
local function notify(err) vim.notify(err, vim.log.levels.WARN) end

function M.complete(start, base)
  if start == 1 then
    local col = vim.fn.col('.') - 1
    local before = vim.api.nvim_get_current_line():sub(1, col)
    return before:match('^%s*%a*$') and (before:find('%a') or (#before + 1)) - 1 or -3
  end
  local choices = { 'pick', 'reword', 'edit', 'squash', 'fixup', 'drop', 'break', 'exec', 'label', 'reset', 'merge' }
  if vim.bo.filetype == 'gitrebaseplan' then choices = { 'pick', 'reword', 'edit', 'squash', 'fixup', 'drop', 'break', 'exec' } end
  return vim.tbl_filter(function(value) return value:sub(1, #base) == base end, choices)
end

function M.message_float(message, title, save, owner)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden, vim.bo[buf].swapfile = 'wipe', false
  vim.bo[buf].buftype = save and 'acwrite' or 'nofile'
  vim.bo[buf].filetype = 'gitcommit'
  vim.api.nvim_buf_set_name(buf, 'git-rebase-message://' .. buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(message, '\n', { plain = true }))
  vim.bo[buf].modified = false
  local width = math.max(1, math.min(90, vim.o.columns - 4))
  local height = math.max(1, math.min(25, math.max(6, vim.api.nvim_buf_line_count(buf)), vim.o.lines - 4))
  local win = vim.api.nvim_open_win(buf, true, { relative = 'editor', style = 'minimal', border = 'rounded',
    width = width, height = height, row = math.max(0, math.floor((vim.o.lines - height) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)), title = ' ' .. title .. ' ' })
  vim.wo[win].wrap, vim.wo[win].linebreak = true, true
  local function close()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end
  local function write()
    if owner and not vim.api.nvim_buf_is_valid(owner) then notify('The rebase plan was closed'); return end
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n'):gsub('\n+$', '')
    if not text:match('^[^\n]*%S') then notify('Commit subject cannot be empty'); return end
    local ok, err = save(text)
    if not ok then notify(err); return end
    vim.bo[buf].modified = false
    close()
  end
  local function quit()
    if save and vim.bo[buf].modified then
      local choice = vim.fn.confirm('Save this message to the rebase plan?', '&Save\n&Discard\n&Cancel', 3)
      if choice == 1 then write(); return elseif choice ~= 2 then return end
    end
    close()
  end
  for _, key in ipairs({ 'q', '<Esc>' }) do vim.keymap.set('n', key, quit, { buffer = buf, silent = true }) end
  if save then
    vim.api.nvim_create_autocmd('BufWriteCmd', { buffer = buf, callback = write })
    vim.keymap.set({ 'n', 'i' }, '<C-s>', write, { buffer = buf, silent = true })
    vim.keymap.set('n', 'ZZ', write, { buffer = buf, silent = true })
  else vim.bo[buf].modifiable = false end
  if owner then
    vim.api.nvim_create_autocmd({ 'BufUnload', 'BufWipeout' }, { buffer = owner, once = true, callback = close })
  end
  return buf, win
end

function M.attach(buf, opts)
  opts = opts or {}
  vim.bo[buf].completefunc = "v:lua.require'git.features.rebase_todo'.complete"
  vim.keymap.set('i', '<C-x><C-u>', '<C-x><C-u>', { buffer = buf, silent = true })
  local function set_action(action)
    if not vim.bo[buf].modifiable then notify('This plan is paused; use cT to edit the live todo'); return end
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
    local name = line:match('^%s*(%a+)%s+%x+%s+')
    if not name or not (actions[name] or vim.tbl_contains(vim.tbl_values(actions), name)) then
      notify('Choose a commit row'); return
    end
    vim.api.nvim_buf_set_lines(buf, row - 1, row, false, { (line:gsub('^(%s*)%a+', '%1' .. action, 1)) })
  end
  for action, key in pairs(actions) do
      vim.keymap.set('n', 'c' .. key, function() set_action(action) end,
        { buffer = buf, silent = true, desc = 'Todo: ' .. action })
  end
  vim.keymap.set('n', 'ca', function()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    local choices = { 'pick', 'reword', 'edit', 'squash', 'fixup', 'drop' }
    vim.ui.select(choices, { prompt = 'Rebase action' }, function(choice)
      if not choice then return end
      if not vim.api.nvim_buf_is_valid(buf) or vim.api.nvim_buf_get_changedtick(buf) ~= tick then
        notify('Todo changed; choose the action again'); return
      end
      vim.api.nvim_buf_call(buf, function()
        vim.api.nvim_win_set_cursor(0, { row, 0 }); set_action(choice)
      end)
    end)
  end, { buffer = buf, silent = true, desc = 'Choose rebase action' })
  local function insert_control(kind)
    if not vim.bo[buf].modifiable then notify('This plan is paused; continue or edit the live todo'); return end
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    local function insert(command)
      if not vim.api.nvim_buf_is_valid(buf) or not vim.bo[buf].modifiable
        or vim.api.nvim_buf_get_changedtick(buf) ~= tick then notify('Todo changed; insert again'); return end
      if kind == 'exec' and (not command or not command:find('%S')) then return end
      if command and command:find('[%z\r\n]') then notify('Exec must be a single shell command line'); return end
      vim.api.nvim_buf_set_lines(buf, row, row, false, { kind .. (command and (' ' .. command) or '') })
      if vim.api.nvim_get_current_buf() == buf then vim.api.nvim_win_set_cursor(0, { row + 1, 0 }) end
    end
    if kind == 'break' then insert() else vim.ui.input({ prompt = 'Exec shell command (runs during rebase): ' }, insert) end
  end
  vim.keymap.set('n', 'cb', function() insert_control('break') end, { buffer = buf, desc = 'Insert break after row' })
  vim.keymap.set('n', 'cx', function() insert_control('exec') end, { buffer = buf, desc = 'Insert exec after row' })
  if not opts.plan then
    local function paint() require('git.features.panel_highlight').rebase(buf) end
    paint()
    vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, { buffer = buf, callback = paint })
  end
  if opts.show_message then
    vim.keymap.set('n', 'gk', opts.show_message, { buffer = buf, silent = true, desc = 'Commit message' })
  elseif opts.root then
    vim.keymap.set('n', 'gk', function()
      local name, hash = vim.api.nvim_get_current_line():match('^%s*(%a+)%s+(%x+)%s+')
      if not name or not (actions[name] or vim.tbl_contains(vim.tbl_values(actions), name)) then hash = nil end
      if not hash then notify('Choose a commit row'); return end
      require('git.features.async').run(opts.root, function()
        local message, err = require('git.features.commit_model').git(opts.root, { 'show', '-s', '--format=%B', hash })
        if not message then error(err, 0) end
        return message:gsub('\n+$', '')
      end, function(ok, message)
        if not vim.api.nvim_buf_is_valid(buf) then return end
        if not ok then notify(message); return end
        M.message_float(message, 'Message ' .. hash, nil, buf)
      end)
    end, { buffer = buf, silent = true, desc = 'Preview commit message; cr marks reword' })
  end
  if not opts.plan then
    vim.keymap.set('n', 'g?', function()
      M.message_float(table.concat({ 'Git rebase todo', '',
        'dd/p/P: reorder; i/A: edit; u: undo edits.',
        'ca: choose action; cp/cr/ce/cs/cf/cd: pick/reword/edit/squash/fixup/drop.',
        'cb/cx: insert break/exec after this row; exec is a shell command.',
        'Ctrl-a/Ctrl-x: cycle action (dial.nvim); Ctrl-x Ctrl-u: complete action.',
        'gk: preview the original message.',
        'Git ignores the subject text in this live todo. Use reword to edit messages.',
        ':write saves the todo; close its buffer to let Git proceed.',
      }, '\n'), 'Rebase todo help', nil, buf)
    end, { buffer = buf, silent = true })
  end
end

return M
