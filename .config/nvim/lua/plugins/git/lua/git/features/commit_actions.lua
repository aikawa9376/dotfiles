-- Shared patch selection and message editing for the independent commit UI.
local M = {}
local utils = require("git.utils")

-- Helpers for X: discard diff changes from commit
local function get_diff_context_at_line(bufnr, lnum)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local on_file_header = (lines[lnum] or ''):match('^diff %-%-git') ~= nil
  local filepath, file_lnum = nil, nil
  for i = lnum, 1, -1 do
    local p = lines[i]:match('^diff %-%-git [ab]/(.+) [ab]/')
    if p then filepath, file_lnum = p, i; break end
  end
  local hunk_start = nil
  if not on_file_header then
    for i = lnum, 1, -1 do
      if lines[i]:match('^@@') then hunk_start = i; break end
      if lines[i]:match('^diff %-%-git') then break end
    end
  end
  return filepath, file_lnum, on_file_header, hunk_start, lines
end

local function collect_hunk_patch(lines, file_lnum, hunk_start)
  local result = {}
  for i = file_lnum, hunk_start - 1 do
    local l = lines[i]
    if l:match('^diff %-%-git') or l:match('^index ') or l:match('^old mode')
      or l:match('^new mode') or l:match('^new file') or l:match('^deleted file')
      or l:match('^rename') or l:match('^similarity')
      or l:match('^%-%-%-') or l:match('^%+%+%+') then
      table.insert(result, l)
    end
  end
  table.insert(result, lines[hunk_start])
  for i = hunk_start + 1, #lines do
    local l = lines[i]
    if l:match('^@@') or l:match('^diff %-%-git') then break end
    table.insert(result, l)
  end
  return result
end

-- Build a patch that individually reverses only the selected +/- lines (zero-context hunks)
local function build_partial_reverse_patch(filepath, lines, hunk_start, sel_start, sel_end)
  local header = lines[hunk_start]
  local old_s, new_s = header:match('^@@ %-(%d+),?%d* %+(%d+),?%d* @@')
  if not old_s then return nil end
  local old_cur, new_cur = tonumber(old_s), tonumber(new_s)
  local sub_hunks = {}
  for i = hunk_start + 1, #lines do
    local l = lines[i]
    if l:match('^@@') or l:match('^diff %-%-git') then break end
    local prefix, content = l:sub(1, 1), l:sub(2)
    local in_sel = (i >= sel_start and i <= sel_end)
    if prefix == ' ' then
      old_cur, new_cur = old_cur + 1, new_cur + 1
    elseif prefix == '-' then
      if in_sel then
        -- Add back the deleted line at the current position in the new (commit) file
        table.insert(sub_hunks, '@@ -' .. new_cur .. ',0 +' .. new_cur .. ',1 @@')
        table.insert(sub_hunks, '+' .. content)
      end
      old_cur = old_cur + 1
    elseif prefix == '+' then
      if in_sel then
        -- Remove the added line at the current position in the new (commit) file
        table.insert(sub_hunks, '@@ -' .. new_cur .. ',1 +' .. new_cur .. ',0 @@')
        table.insert(sub_hunks, '-' .. content)
      end
      new_cur = new_cur + 1
    end
  end
  if #sub_hunks == 0 then return nil end
  local patch = {
    'diff --git a/' .. filepath .. ' b/' .. filepath,
    '--- a/' .. filepath,
    '+++ b/' .. filepath,
  }
  vim.list_extend(patch, sub_hunks)
  return patch
end

local function cleanup_view_file(path)
  if path then
    os.remove(path)
  end
end

local function clamp_line(line, max_line)
  return math.max(1, math.min(line, math.max(max_line, 1)))
end

local function find_file_header_line(lines, filepath)
  if not filepath then
    return nil
  end

  local pattern = '^diff %-%-git [ab]/' .. vim.pesc(filepath) .. ' [ab]/'
  for i, line in ipairs(lines) do
    if line:match(pattern) then
      return i
    end
  end
end

local function find_file_end_line(lines, file_lnum)
  if not file_lnum then
    return #lines
  end

  for i = file_lnum + 1, #lines do
    if lines[i]:match('^diff %-%-git') then
      return i - 1
    end
  end

  return #lines
end

local function find_hunk_header_line(lines, file_lnum, hunk_header)
  if not file_lnum or not hunk_header then
    return nil
  end

  for i = file_lnum + 1, #lines do
    local line = lines[i]
    if line:match('^diff %-%-git') then
      break
    end
    if line == hunk_header then
      return i
    end
  end
end

local function find_hunk_end_line(lines, hunk_lnum)
  if not hunk_lnum then
    return #lines
  end

  for i = hunk_lnum + 1, #lines do
    local line = lines[i]
    if line:match('^@@') or line:match('^diff %-%-git') then
      return i - 1
    end
  end

  return #lines
end

local function open_file_fold(file_lnum)
  if not file_lnum or vim.fn.foldclosed(file_lnum) == -1 then
    return false
  end

  return pcall(function()
    vim.cmd(('silent! %dfoldopen!'):format(file_lnum))
  end)
end

local function save_commit_view_state(bufnr)
  local win = vim.api.nvim_get_current_win()
  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  local filepath, file_lnum, _, hunk_start, lines = get_diff_context_at_line(bufnr, lnum)
  local state = {
    win = win,
    view = vim.fn.winsaveview(),
    view_file = vim.fn.tempname(),
    filepath = filepath,
    file_offset = file_lnum and (lnum - file_lnum) or nil,
    hunk_header = hunk_start and lines[hunk_start] or nil,
    hunk_offset = hunk_start and (lnum - hunk_start) or nil,
  }

  local ok = pcall(function()
    vim.api.nvim_win_call(win, function()
      vim.cmd('silent! mkview! ' .. vim.fn.fnameescape(state.view_file))
    end)
  end)

  if not ok then
    cleanup_view_file(state.view_file)
    state.view_file = nil
  end

  return state
end

local function restore_commit_view_state(state)
  if not state then
    return
  end

  if not vim.api.nvim_win_is_valid(state.win) then
    cleanup_view_file(state.view_file)
    return
  end

  vim.api.nvim_win_call(state.win, function()
    if state.view_file then
      pcall(function()
        vim.cmd('silent! loadview ' .. vim.fn.fnameescape(state.view_file))
      end)
    end

    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local max_line = math.max(#lines, 1)
    local target_line = clamp_line(state.view.lnum or 1, max_line)
    local file_lnum = find_file_header_line(lines, state.filepath)

    if file_lnum then
      local hunk_lnum = find_hunk_header_line(lines, file_lnum, state.hunk_header)
      if hunk_lnum and state.hunk_offset then
        target_line = clamp_line(
          math.min(hunk_lnum + state.hunk_offset, find_hunk_end_line(lines, hunk_lnum)),
          max_line
        )
      elseif state.file_offset then
        target_line = clamp_line(
          math.min(file_lnum + state.file_offset, find_file_end_line(lines, file_lnum)),
          max_line
        )
      else
        target_line = clamp_line(file_lnum, max_line)
      end
    end

    local view = vim.deepcopy(state.view)
    local screen_offset = math.max((state.view.lnum or 1) - (state.view.topline or 1), 0)
    view.lnum = target_line
    view.topline = clamp_line(target_line - screen_offset, max_line)
    pcall(function()
      vim.fn.winrestview(view)
    end)

    local opened = open_file_fold(file_lnum)
    pcall(function()
      vim.cmd('silent! normal! zv')
    end)
    if opened then
      pcall(function()
        vim.fn.winrestview(view)
      end)
    end
  end)

  cleanup_view_file(state.view_file)
end

local function reopen_commit_preserving_view(new_hash, state)
  if new_hash == '' then
    restore_commit_view_state(state)
    return
  end

  vim.schedule(function()
    local ok, err = pcall(function()
      vim.cmd('Gedit ' .. new_hash)
    end)
    if not ok then
      cleanup_view_file(state and state.view_file or nil)
      vim.notify('Failed to reopen commit: ' .. err, vim.log.levels.ERROR)
      return
    end

    vim.schedule(function()
      restore_commit_view_state(state)
    end)
  end)
end

-- Commit message edit float + amend flow
local edit_float_win = nil
local edit_float_buf = nil
local edit_context_by_buf = {}

local function close_edit_commit_float(bufnr)
  bufnr = bufnr or edit_float_buf
  -- Mark buffer as intentionally closing to skip unload prompt
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(function() vim.b[bufnr].amend_closing = true end)
  end

  if edit_float_win and vim.api.nvim_win_is_valid(edit_float_win) then
    pcall(vim.api.nvim_win_close, edit_float_win, true)
  end
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
  if bufnr then edit_context_by_buf[bufnr] = nil end
  edit_float_win = nil
  edit_float_buf = nil
end

local function do_amend_commit_from_file(git_dir, commit, message_file, view_state, opts)
  opts = opts or {}
  if opts.rewrite_message then
    local hash, err = opts.rewrite_message(vim.fn.readfile(message_file))
    if not hash then vim.notify(err, vim.log.levels.ERROR); return false end
    if opts.on_complete then opts.on_complete(hash) end
    if err then vim.notify(err, vim.log.levels.WARN) end
    return true
  end
  if not git_dir or git_dir == '' then
    vim.notify('Not in a git repository', vim.log.levels.ERROR)
    return false
  end
  local new_hash, err = require('git.features.commit_rewrite').apply(git_dir, commit, {
    message = vim.fn.readfile(message_file),
  })
  if not new_hash then vim.notify(err, vim.log.levels.ERROR); return false end
  if err then vim.notify(err, vim.log.levels.WARN) end

  if opts.reopen ~= false then
    reopen_commit_preserving_view(new_hash, view_state)
  end
  if opts.on_complete then pcall(opts.on_complete, new_hash) end
  vim.notify('Amended commit ' .. (commit:sub(1,7)) .. ' → ' .. (new_hash and new_hash:sub(1,7) or ''), vim.log.levels.INFO)
  return true
end

local function open_edit_commit_float(commit, origin_buf, view_state, opts)
  -- If float already open, replace content
  pcall(close_edit_commit_float)

  local work_tree = utils.get_buf_work_tree(origin_buf)
    or utils.set_buf_work_tree(origin_buf, utils.get_work_tree({ bufnr = origin_buf }))
  local git_prefix = work_tree and ('git -C ' .. vim.fn.shellescape(work_tree) .. ' ') or 'git '
  local msg = vim.fn.systemlist(git_prefix .. 'show -s --format=%B ' .. vim.fn.shellescape(commit))
  if vim.v.shell_error ~= 0 or not msg then msg = { '' } end
  while #msg > 0 and msg[#msg] == '' do table.remove(msg) end

  edit_float_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[edit_float_buf].buftype = 'nofile'
  vim.bo[edit_float_buf].bufhidden = 'wipe'
  vim.bo[edit_float_buf].swapfile = false
  vim.bo[edit_float_buf].filetype = 'gitcommit'
  vim.api.nvim_buf_set_lines(edit_float_buf, 0, -1, false, msg)
  vim.bo[edit_float_buf].modifiable = true

  local width = math.min(80, vim.o.columns - 4)
  local height = math.min(30, math.max(6, #msg))
  local col = math.floor((vim.o.columns - width) / 2)
  local row = math.floor((vim.o.lines - height) / 2)

  edit_float_win = vim.api.nvim_open_win(edit_float_buf, true, {
    relative = 'editor', width = width, height = height, col = col, row = row,
    style = 'minimal', border = 'single', title = ' Amend commit ', title_pos = 'center',
  })

  -- Keymaps: 'q' and <Esc> will trigger the close-with-prompt flow. <Leader>a still triggers amend directly.
  vim.api.nvim_buf_set_keymap(edit_float_buf, 'n', 'q', [[:lua require('git.features.commit_actions')._close_edit_float()<CR>]],
    { noremap = true, silent = true, nowait = true })
  vim.api.nvim_buf_set_keymap(edit_float_buf, 'n', '<Esc>', [[:lua require('git.features.commit_actions')._close_edit_float()<CR>]], { noremap = true, silent = true })
  vim.api.nvim_buf_set_keymap(edit_float_buf, 'n', '<Leader>a', [[:lua require('git.features.commit_actions')._do_amend_from_buffer()<CR>]], { noremap = true, silent = true })

  -- Store state for the buffer via buffer variable
  vim.b[edit_float_buf].amend_target = commit
  vim.b[edit_float_buf].amend_origin_buf = origin_buf
  vim.b[edit_float_buf].amend_work_tree = work_tree
  vim.b[edit_float_buf].amend_view_state = view_state
  vim.b[edit_float_buf].amend_original_text = table.concat(msg, '\n')
  edit_context_by_buf[edit_float_buf] = opts or {}

  -- Prompt on unexpected buffer unload/close: if buffer is unloaded while not intentionally closing, run prompt handler
  vim.api.nvim_create_autocmd({ 'BufUnload' }, {
    buffer = edit_float_buf,
    callback = function(ev)
      vim.schedule(function()
        local b = ev.buf
        -- If buffer is already invalid, nothing to do
        if not b or not pcall(vim.api.nvim_buf_is_valid, b) or not vim.api.nvim_buf_is_valid(b) then
          return
        end
        -- If buffer is flagged as intentionally closing, do nothing
        if vim.b[b] and vim.b[b].amend_closing then
          return
        end
        -- Otherwise, invoke the close-with-prompt handler
        pcall(function()
          require('git.features.commit_actions')._close_edit_float(b)
        end)
      end)
    end,
  })
end

-- Close-with-prompt wrapper. If buffer content changed, ask user to apply (amend) or discard changes.
M._close_edit_float = function(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end

  -- If flagged as intentionally closing, just close
  if vim.b[bufnr] and vim.b[bufnr].amend_closing then
    close_edit_commit_float(bufnr)
    return
  end

  local orig = vim.b[bufnr] and vim.b[bufnr].amend_original_text or nil
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local cur = table.concat(lines, '\n')

  if not orig or orig == cur then
    -- Nothing changed
    close_edit_commit_float(bufnr)
    return
  end

  local commit = vim.b[bufnr] and vim.b[bufnr].amend_target or ''
  local short = (commit and commit ~= '') and tostring(commit):sub(1,7) or ''

  local choice = vim.fn.confirm(
    string.format('Apply changes to commit %s?', short),
    '&Yes\n&No\n&Cancel', 1
  )

  if choice == 1 then
    -- Apply (amend) and close
    M._do_amend_from_buffer(bufnr, true)
    return
  elseif choice == 2 then
    -- Close without applying
    close_edit_commit_float(bufnr)
    return
  else
    -- Cancel: keep open
    return
  end
end

-- Perform amend from given buffer (or current buf)
M._do_amend_from_buffer = function(bufnr, skip_confirm)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local commit = vim.b[bufnr] and vim.b[bufnr].amend_target or nil
  local origin_buf = vim.b[bufnr] and vim.b[bufnr].amend_origin_buf or nil
  local view_state = vim.b[bufnr] and vim.b[bufnr].amend_view_state or nil
  local opts = edit_context_by_buf[bufnr] or {}
  if not commit then
    vim.notify('No amend target', vim.log.levels.ERROR)
    return
  end

  -- Light confirmation unless explicitly skipped
  if not skip_confirm then
    local short = tostring(commit):sub(1, 7)
    local choice = vim.fn.confirm('Amend commit ' .. short .. '?', '&Yes\n&No', 1)
    if choice ~= 1 then
      vim.notify('Amend cancelled', vim.log.levels.INFO)
      return
    end
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local temp = vim.fn.tempname()
  local f = io.open(temp, 'w')
  if not f then vim.notify('Failed to create temp file', vim.log.levels.ERROR); return end
  f:write(table.concat(lines, '\n') .. '\n')
  f:close()

  local git_dir = vim.b[bufnr] and vim.b[bufnr].amend_work_tree
    or (origin_buf and utils.get_buf_work_tree(origin_buf))
  if not git_dir then
    vim.notify('Not in a git repository', vim.log.levels.ERROR)
    os.remove(temp)
    return
  end
  local ok = do_amend_commit_from_file(git_dir, commit, temp, view_state, opts)
  os.remove(temp)
  if ok then close_edit_commit_float(bufnr) end
end


local function confirm_discard_mode(scope, commit)
  local choice = vim.fn.confirm(
    table.concat({
      string.format('Discard %s changes from commit %s?', scope, commit:sub(1, 7)),
      '',
      'Hard: remove them from the commit and worktree',
      'Mixed: remove them from the commit and keep them unstaged',
    }, '\n'),
    '&Hard\n&Mixed\n&Cancel',
    3
  )

  if choice == 1 then
    return 'hard'
  end
  if choice == 2 then
    return 'mixed'
  end
end

M.open_edit_commit = function(commit, origin_buf, opts)
  opts = opts or {}
  local view_state = opts.reopen == false and nil or save_commit_view_state(origin_buf)
  open_edit_commit_float(commit, origin_buf, view_state, opts)
end

-- Shared patch selection semantics for the custom commit view.
M.collect_hunk_patch = collect_hunk_patch
M.build_partial_reverse_patch = build_partial_reverse_patch
M.confirm_discard_mode = confirm_discard_mode

return M
