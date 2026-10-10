-- Existing review threads, including outdated/file comments, with a reply draft.
local M = {}
local github = require('git.features.github')
local actions = require('git.features.github_actions')
local serial = 0
function M.open(ctx, thread)
  serial = serial + 1
  local prefix = { ('PR #%d · %s%s'):format(ctx.number, thread.path,
    thread.line and (':' .. thread.line .. ' (' .. (thread.side or 'RIGHT') .. ')') or ' (file / outdated)'), '' }
  for _, comment in ipairs(thread.comments) do
    prefix[#prefix + 1] = '@' .. (comment.user and comment.user.login or 'unknown') .. ' · ' .. (comment.created_at or '')
    vim.list_extend(prefix, vim.split(comment.body or '', '\n', { plain = true }))
    prefix[#prefix + 1] = ''
  end
  vim.list_extend(prefix, { 'Reply below; :w sends to GitHub', '────────────────────────────' })
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, ('git-pr-reply://%s/%s/%d/%d'):format(ctx.host, ctx.repo, thread.id, serial))
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = 'acwrite', 'hide', false
  vim.bo[buf].filetype, vim.bo[buf].undofile = 'markdown', false
  require('git.utils').set_buf_work_tree(buf, ctx.root)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.list_extend(vim.deepcopy(prefix), { '' }))
  vim.bo[buf].modified = false
  local width, height = math.max(1, math.min(100, vim.o.columns - 4)), math.max(1, math.min(#prefix + 8, vim.o.lines - 5))
  local win = vim.api.nvim_open_win(buf, true, { relative = 'editor', style = 'minimal', border = 'rounded',
    width = width, height = height, col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    row = math.max(0, math.floor((vim.o.lines - height) / 2)), title = ' PR thread / reply ' })
  vim.wo[win].wrap = true
  vim.api.nvim_win_set_cursor(win, { #prefix + 1, 0 })
  local saving = false
  local function close()
    if vim.bo[buf].modified and vim.fn.confirm('Discard unsent reply?', '&Discard\n&Keep', 2) ~= 1 then return end
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  vim.keymap.set('n', 'q', close, { buffer = buf, silent = true })
  vim.keymap.set('n', 'gx', function() vim.ui.open(thread.url or ctx.url) end, { buffer = buf, silent = true })
  vim.api.nvim_create_autocmd('BufWriteCmd', { buffer = buf, callback = function(ev)
    if ev.match ~= vim.api.nvim_buf_get_name(buf) then error('Use :w without a filename to send this reply') end
    if saving then error('Reply is already being sent') end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    for i, value in ipairs(prefix) do if lines[i] ~= value then error('Existing comments are read-only; undo those edits') end end
    local body = table.concat(vim.list_slice(lines, #prefix + 1), '\n')
    if vim.trim(body) == '' then error('Reply cannot be empty') end
    saving = true
    vim.bo[buf].modifiable = false
    actions.run(ctx, function(resolved)
      return github.api(resolved, ('repos/%s/pulls/%d/comments/%d/replies'):format(resolved.repo, resolved.number, thread.id), { body = body })
    end, function()
      saving = false
      vim.notify('Reply sent')
      if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
    end, true, function()
      saving = false
      if vim.api.nvim_buf_is_valid(buf) then vim.bo[buf].modifiable = true end
    end)
  end })
  return buf
end
function M.select(ctx, threads)
  if #threads == 0 then vim.notify('No review comments here'); return end
  if #threads == 1 then return M.open(ctx, threads[1]) end
  vim.ui.select(threads, { prompt = 'Review threads', format_item = function(thread)
    local comment = thread.comments[1]
    return ('%s%s · @%s: %s'):format(thread.path, thread.line and (':' .. thread.line) or ' (file / outdated)',
      comment.user and comment.user.login or 'unknown', (comment.body or ''):gsub('[\r\n]', ' '))
  end }, function(thread) if thread then M.open(ctx, thread) end end)
end
return M
