local M = {}

---Open a small floating help window with the provided lines.
---@param title string
---@param lines string[]
function M.show(title, lines)
  local parent_win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'fugitivehelp'

  local content = {}
  if title and title ~= '' then
    table.insert(content, title)
    table.insert(content, string.rep('-', math.max(8, vim.fn.strdisplaywidth(title))))
  end
  for _, line in ipairs(lines or {}) do
    table.insert(content, line)
  end

  local width = 0
  for _, line in ipairs(content) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.min(width + 4, math.max(40, width + 2))
  local height = #content

  local opts = {
    relative = 'editor',
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = 'minimal',
    border = 'single',
    title = ' Help ',
    title_pos = 'center',
  }

  local win = vim.api.nvim_open_win(buf, true, opts)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
  vim.keymap.set('n', 'q', function()
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end, { buffer = buf, nowait = true, silent = true })

  vim.keymap.set('n', '<CR>', function()
    local line = vim.api.nvim_get_current_line()
    local key = line:match('^%s*(%S+)')
    if not key then return end

    -- Handle multiple keys separated by /
    if key:find('/') then
      key = vim.split(key, '/')[1]
    end

    -- Close help window
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end

    -- Execute key in parent window
    if parent_win and vim.api.nvim_win_is_valid(parent_win) then
      vim.api.nvim_set_current_win(parent_win)
      local term_key = vim.api.nvim_replace_termcodes(key, true, false, true)
      vim.api.nvim_feedkeys(term_key, 'm', false)
    end
  end, { buffer = buf, nowait = true, silent = true })
end

return M
