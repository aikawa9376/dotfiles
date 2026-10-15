-- A read-only conversation near the PR cursor; viewing never opens a draft.
local M = {}
local previews = {}
function M.close(source)
  local p = previews[source]
  if not p then return end
  previews[source] = nil
  if vim.api.nvim_buf_is_valid(source) then vim.b[source].git_pr_preview = nil end
  if vim.api.nvim_buf_is_valid(p.buf) then vim.api.nvim_buf_delete(p.buf, { force = true }) end
  pcall(vim.api.nvim_del_augroup_by_id, p.group)
end
function M.show(opts)
  if #opts.threads == 0 then M.close(opts.buf); return end
  local cursor = vim.api.nvim_win_get_cursor(opts.win)
  local old = previews[opts.buf]
  if old and vim.api.nvim_win_is_valid(old.win) and old.row == cursor[1]
    and vim.deep_equal(old.threads, opts.threads) and opts.focus then
    vim.api.nvim_set_current_win(old.win); return old.buf
  end
  M.close(opts.buf)
  local history = require('git.features.pr_history')
  local comments, contexts = history.thread_history(opts.ctx, opts.threads)
  local buf, lines, rows = history.buffer({}, comments, opts.viewer, contexts)
  local width = math.max(1, math.min(80, vim.o.columns - 4))
  local size = 0
  for _, line in ipairs(lines) do size = size + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / width)) end
  local height = math.max(1, math.min(size, 16, math.floor(vim.o.lines * 0.45)))
  local screen = vim.fn.screenpos(opts.win, cursor[1], cursor[2] + 1)
  local above = vim.o.lines - screen.row - 3 < height and screen.row > height + 2
  local win = vim.api.nvim_open_win(buf, false, { relative = 'cursor', border = 'rounded', style = 'minimal',
    width = width, height = height, row = above and -1 or 1, anchor = above and 'SW' or 'NW',
    col = math.min(0, vim.o.columns - screen.col - width - 2), title = {
      { ' PR conversation ', 'Title' },
      { '· gc reply · gA actions · gR toggle · gk focus · ]t/[t move · q ', 'GitPrCommentInstruction' },
    } })
  vim.wo[win].wrap, vim.wo[win].linebreak = true, true
  vim.api.nvim_win_set_cursor(win, { #lines, 0 })
  vim.api.nvim_win_call(win, function() vim.cmd('normal! zb') end)
  local group = vim.api.nvim_create_augroup('GitPrPreview' .. buf, { clear = true })
  previews[opts.buf] = { buf = buf, win = win, group = group, row = cursor[1], threads = vim.deepcopy(opts.threads) }
  vim.b[opts.buf].git_pr_preview = buf
  local function source()
    if vim.api.nvim_win_is_valid(opts.win) and vim.api.nvim_win_get_buf(opts.win) == opts.buf then
      vim.api.nvim_set_current_win(opts.win); return true
    end
  end
  local function close() M.close(opts.buf); source() end
  vim.keymap.set('n', { 'q', '<Esc>' }, close, { buffer = buf, silent = true })
  vim.keymap.set('n', 'gA', function()
    local item = rows[vim.fn.line('.')]
    if item and source() then
      M.close(opts.buf)
      require('git.features.pr_comment_actions').menu(opts.ctx, item, opts.viewer)
    end
  end, { buffer = buf, silent = true, desc = 'Comment reactions / edit / delete / apply suggestion' })
  vim.keymap.set('n', 'gc', function() if source() then M.close(opts.buf); opts.reply() end end,
    { buffer = buf, silent = true, desc = 'Reply to PR conversation' })
  vim.keymap.set('n', 'gR', function() if source() then M.close(opts.buf); opts.resolve() end end,
    { buffer = buf, silent = true, desc = 'Resolve / reopen PR conversation' })
  for key, direction in pairs({ [']t'] = 1, ['[t'] = -1, [']C'] = 1, ['[C'] = -1 }) do
    vim.keymap.set('n', key, function()
      local count = vim.v.count1
      if source() then M.close(opts.buf); opts.navigate(direction, count) end
    end, { buffer = buf, silent = true, desc = 'Move to another PR comment' })
  end
  vim.api.nvim_create_autocmd('CursorMoved', { group = group, buffer = opts.buf, callback = function()
    if vim.api.nvim_get_current_win() == opts.win and vim.api.nvim_win_get_cursor(opts.win)[1] ~= cursor[1] then M.close(opts.buf) end
  end })
  vim.api.nvim_create_autocmd('BufEnter', { group = group, callback = function(ev)
    if ev.buf ~= opts.buf and ev.buf ~= buf then M.close(opts.buf) end
  end })
  vim.api.nvim_create_autocmd('WinClosed', { group = group, pattern = tostring(opts.win), callback = function() M.close(opts.buf) end })
  vim.api.nvim_create_autocmd('BufWipeout', { group = group, buffer = opts.buf, callback = function() M.close(opts.buf) end })
  vim.api.nvim_create_autocmd('BufWipeout', { group = group, buffer = buf, callback = function()
    previews[opts.buf] = nil
    if vim.api.nvim_buf_is_valid(opts.buf) then vim.b[opts.buf].git_pr_preview = nil end
    pcall(vim.api.nvim_del_augroup_by_id, group)
  end })
  if opts.viewer then
    local ok, err = pcall(require('git.features.pr_read_state').mark, opts.ctx, opts.viewer, comments)
    if not ok then vim.notify('Could not save comment read state: ' .. tostring(err), vim.log.levels.WARN) end
  end
  return buf
end
return M
