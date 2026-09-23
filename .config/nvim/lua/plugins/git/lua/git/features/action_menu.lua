local M = {}

local function execute(parent_win, win, action)
  if not action.enabled then
    vim.notify(action.disabled_reason or 'Action is unavailable in this context', vim.log.levels.WARN)
    return
  end
  if win and vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  if not (parent_win and vim.api.nvim_win_is_valid(parent_win)) then return end
  vim.api.nvim_set_current_win(parent_win)
  if action.callback then
    action.callback()
  else
    local key = vim.api.nvim_replace_termcodes(action.key, true, false, true)
    vim.api.nvim_feedkeys(key, 'm', false)
  end
end

function M.show(title, groups, opts)
  opts = opts or {}
  local parent_win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'fugitiveactionmenu'

  local lines, actions_by_row, headings = {}, {}, {}
  table.insert(lines, title)
  if opts.context and opts.context ~= '' then table.insert(lines, opts.context) end
  table.insert(lines, '')
  for _, group in ipairs(groups) do
    table.insert(lines, group.title)
    headings[#lines] = true
    for _, action in ipairs(group.actions) do
      if action.enabled == nil then action.enabled = true end
      local marker = action.enabled and ' ' or '·'
      table.insert(lines, ('%s %-10s %s'):format(marker, action.display_key or action.key, action.label))
      actions_by_row[#lines] = action
    end
    table.insert(lines, '')
  end
  if lines[#lines] == '' then table.remove(lines) end

  local width = 46
  for _, line in ipairs(lines) do width = math.max(width, vim.fn.strdisplaywidth(line) + 2) end
  width = math.min(width, math.max(vim.o.columns - 4, 1))
  local height = math.min(#lines, math.max(vim.o.lines - 6, 1))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor', width = width, height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = 'minimal', border = 'single', title = ' Actions ', title_pos = 'center',
  })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local ns = vim.api.nvim_create_namespace('fugitive_action_menu')
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { end_col = #lines[1], hl_group = 'Title' })
  for row in pairs(headings) do
    vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, { end_col = #lines[row], hl_group = 'Type' })
  end
  for row, action in pairs(actions_by_row) do
    if not action.enabled then
      vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, { end_col = #lines[row], hl_group = 'Comment' })
    end
  end

  local function close()
    if win and vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end
  vim.keymap.set('n', 'q', close, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set('n', '<Esc>', close, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set('n', '<CR>', function()
    local action = actions_by_row[vim.api.nvim_win_get_cursor(0)[1]]
    if action then execute(parent_win, win, action) end
  end, { buffer = buf, nowait = true, silent = true })

  local mapped = {}
  for _, action in pairs(actions_by_row) do
    if action.enabled and action.key ~= 'q' and not mapped[action.key] then
      mapped[action.key] = true
      vim.keymap.set('n', action.key, function() execute(parent_win, win, action) end,
        { buffer = buf, nowait = true, silent = true })
    end
  end
end

return M
