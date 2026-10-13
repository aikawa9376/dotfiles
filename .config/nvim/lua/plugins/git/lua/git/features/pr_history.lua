-- Context and conversation live above the compact input in an immutable buffer.
local M = {}
function M.buffer(prefix, comments, viewer)
  local lines, spans, rows = vim.deepcopy(prefix), {}, {}
  if #lines > 0 and comments and #comments > 0 and lines[#lines] ~= '' then lines[#lines + 1] = '' end
  for index, comment in ipairs(comments or {}) do
    if index > 1 then lines[#lines + 1] = '' end
    local first = #lines
    if require('git.features.pr_timeline').is_event(comment) then
      local chunks, line = require('git.features.pr_timeline').chunks(comment, viewer), ''
      for _, chunk in ipairs(chunks) do chunk[1] = chunk[1]:gsub('[\r\n\t]', ' '); line = line .. chunk[1] end
      lines[#lines + 1], rows[#lines + 1] = line, comment
      spans[#spans + 1] = { first = first, chunks = chunks }
    else
      local author = comment.user and comment.user.login or 'unknown'
      lines[#lines + 1] = '@' .. author .. (author == viewer and ' · you' or '')
        .. (comment.pending and ' [pending]' or '') .. ' · ' .. (comment.created_at or '')
        .. (comment.review_state and (' · Review ' .. comment.review_state) or '')
      local body = vim.split(comment.body or '', '\n', { plain = true })
      while #body > 0 and body[#body]:match('^%s*$') do table.remove(body) end
      vim.list_extend(lines, body)
      local reactions = require('git.features.pr_reactions').format(comment.reactions)
      if reactions ~= '' then lines[#lines + 1] = reactions end
      for at = first + 1, #lines do rows[at] = comment end
      spans[#spans + 1] = { first = first, last = #lines, own = author == viewer }
    end
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden, vim.bo[buf].filetype, vim.bo[buf].swapfile = 'wipe', 'markdown', false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable, vim.bo[buf].readonly, vim.bo[buf].modified = false, true, false
  vim.api.nvim_set_hl(0, 'GitPrCommentSelf', { default = true, link = 'DiagnosticInfo' })
  vim.api.nvim_set_hl(0, 'GitPrCommentOther', { default = true, link = 'Normal' })
  vim.api.nvim_set_hl(0, 'GitPrCommentContext', { default = true, link = 'Title' })
  vim.api.nvim_set_hl(0, 'GitPrCommentInstruction', { default = true, link = 'Comment' })
  local ns = vim.api.nvim_create_namespace('git_pr_history')
  for at, line in ipairs(prefix) do
    vim.api.nvim_buf_set_extmark(buf, ns, at - 1, 0, { end_col = #line,
      hl_group = 'GitPrCommentContext', priority = 160 })
    for label, group in pairs({ ['✅ resolved'] = 'GitPrPositive', ['💬 unresolved'] = 'DiagnosticInfo',
      ['💬 status unavailable'] = 'Comment', ['📝 pending'] = 'DiagnosticWarn' }) do
      local start, finish = line:find(label, 1, true)
      if start then vim.api.nvim_buf_set_extmark(buf, ns, at - 1, start - 1,
        { end_col = finish, hl_group = group, priority = 170 }) end
    end
  end
  for _, span in ipairs(spans) do
    if span.chunks then
      local col = 0
      for _, chunk in ipairs(span.chunks) do
        vim.api.nvim_buf_set_extmark(buf, ns, span.first, col,
          { end_col = col + #chunk[1], hl_group = chunk[2], priority = 160 })
        col = col + #chunk[1]
      end
    else
      for at = span.first, span.last - 1 do
        vim.api.nvim_buf_set_extmark(buf, ns, at, 0, { end_col = #lines[at + 1],
          hl_group = span.own and 'GitPrCommentSelf' or 'GitPrCommentOther', priority = 150 })
      end
      vim.api.nvim_buf_set_extmark(buf, ns, span.first, 0, { end_col = #lines[span.first + 1],
        hl_group = span.own and 'GitPrCommentSelf' or 'DiagnosticWarn', priority = 160 })
    end
  end
  return buf, lines, rows
end
function M.attach(input, win, comments, viewer, prefix, close, hint)
  local buf, lines, rows = M.buffer(prefix, comments, viewer)
  local config = vim.api.nvim_win_get_config(win)
  local context_height, content_height = 0, 0
  for at, line in ipairs(lines) do
    local size = math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / config.width))
    if at <= #prefix then context_height = context_height + size else content_height = content_height + size end
  end
  local height = math.max(1, math.min(context_height + math.min(content_height, 10), vim.o.lines - config.height - 9))
  local total = height + config.height + 4
  local row = math.max(0, math.floor((vim.o.lines - total - 2) / 2))
  vim.api.nvim_win_set_config(win, { relative = 'editor', col = config.col, row = row + height + 2 })
  local history = vim.api.nvim_open_win(buf, false, { relative = 'editor', style = 'minimal', border = 'rounded',
    width = config.width, height = height, col = config.col, row = row,
    title = { { ' Context / conversation ', 'Title' },
      { '· ' .. (hint and (hint .. ' · ') or '') .. 'Tab input · <C-s> send · q ', 'GitPrCommentInstruction' } } })
  vim.wo[history].wrap, vim.wo[history].linebreak = true, true
  vim.b[input].git_pr_context = buf
  vim.keymap.set('n', 'gA', function()
    local item = rows[vim.fn.line('.')]
    if item then require('git.features.pr_comment_actions').menu(vim.b[input].git_pr_ctx, item, viewer) end
  end, { buffer = buf, silent = true, desc = 'Comment reactions / edit / delete / apply suggestion' })
  if comments and #comments > 0 then vim.b[input].git_pr_history = buf end
  vim.keymap.set('n', '<Tab>', function() if vim.api.nvim_win_is_valid(history) then vim.api.nvim_set_current_win(history) end end,
    { buffer = input, silent = true, desc = 'Read conversation history' })
  vim.keymap.set('n', '<Tab>', function() if vim.api.nvim_win_is_valid(win) then vim.api.nvim_set_current_win(win) end end,
    { buffer = buf, silent = true, desc = 'Return to comment input' })
  vim.keymap.set('n', 'q', close, { buffer = buf, silent = true })
  vim.keymap.set('n', '<C-s>', function() vim.api.nvim_buf_call(input, function() vim.cmd('write') end) end,
    { buffer = buf, silent = true, desc = 'Send / save PR draft' })
  local function cleanup()
    if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
  end
  local group = vim.api.nvim_create_augroup('GitPrHistory' .. input, { clear = true })
  vim.api.nvim_create_autocmd('WinClosed', { group = group, pattern = tostring(win), once = true, callback = cleanup })
  vim.api.nvim_create_autocmd('BufWipeout', { group = group, buffer = input, once = true, callback = function()
    cleanup(); pcall(vim.api.nvim_del_augroup_by_id, group)
  end })
end
return M
