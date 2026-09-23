local M = {}

local function parse_line(line)
  local display_key, label = line:match('^%s*(.-)%s%s+(.+)$')
  if not display_key then display_key, label = line:match('^%s*(%S+)%s+(.+)$') end
  if not display_key then return nil end

  local key = display_key:match('^([^%s/]+)')
  if not key then return nil end
  return { key = key, display_key = display_key, label = label }
end

---Show help using the shared Fugitive action menu.
---@param title string
---@param lines string[]
function M.show(title, lines)
  local actions = {}
  for _, line in ipairs(lines or {}) do
    local action = parse_line(line)
    if action then table.insert(actions, action) end
  end
  require('git.features.action_menu').show(title, {
    { title = 'Actions', actions = actions },
  })
end

---Show longer key guides as one readable column, independent of action-menu keys.
---@param title string
---@param entries string[]
function M.show_text(title, entries)
  local lines = { title, '' }
  vim.list_extend(lines, entries or {})
  vim.list_extend(lines, { '', 'q / <Esc>  close' })
  local max_width = 0
  for _, line in ipairs(lines) do max_width = math.max(max_width, vim.fn.strdisplaywidth(line)) end
  local width = math.min(math.max(max_width + 2, 40), math.max(vim.o.columns - 4, 1))
  local visual_height = 0
  for _, line in ipairs(lines) do
    visual_height = visual_height + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / width))
  end
  local height = math.min(visual_height, math.max(vim.o.lines - 6, 1))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = 'nofile', 'wipe', false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor', width = width, height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = 'minimal', border = 'single', title = ' Help ', title_pos = 'center',
  })
  vim.wo[win].wrap, vim.wo[win].linebreak, vim.wo[win].breakindent = true, true, true
  vim.wo[win].breakindentopt = 'shift:2'
  vim.api.nvim_buf_set_extmark(buf, vim.api.nvim_create_namespace('git_help'), 0, 0,
    { end_col = #title, hl_group = 'Title' })
  local function close() if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end end
  for _, key in ipairs({ 'q', '<Esc>' }) do
    vim.keymap.set('n', key, close, { buffer = buf, silent = true, nowait = true })
  end
  return buf, win
end

return M
