local M = {}

function _G.code_action_complete(win)
  local choice = vim.trim(vim.fn.getline('.'))
  local index = tonumber(string.match(choice, "%d+"))
  local result = vim.api.nvim_buf_get_var(0, 'code_action_result')
  if not index or index < 1 or index > #result then
    return
  end
  -- ここでウインドウを閉じないと関連のrequestがbufの関係でエラーになる
  vim.api.nvim_win_close(win, true)

  if index < 1 or index > #result then
    _G.code_action_on_choice(nil, nil)
  else
    _G.code_action_on_choice(result[index], index)
  end
end

local function get_titles_length(result, prompt, format_item)
  local option_strings = {prompt or 'Code actions:'}
  local length = 0
  local title
  for i, action in ipairs(result) do
    if #action > 1 then
      title = string.format("%d. %s [%s]", i, format_item(action), action[2].kind)
    else
      title = string.format("%d. %s", i, format_item(action))
    end
    table.insert(option_strings, title)

    length = length < #title and #title or length
  end
  return option_strings, length
end

local function float_ui_select(items, opts, on_choice)
  local prompt = opts.prompt or "Select one of:"
  local format_item = opts.format_item or tostring

  local title, length = get_titles_length(items, prompt, format_item)
  local w_opts = {
    relative = 'cursor', row = 1,
    col = 0, width = length,
    height = #title, style = 'minimal'
  }
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, w_opts)
  _G.code_action_on_choice = on_choice

  local fmt =  '<cmd>lua code_action_complete(%d)<CR>'
  vim.api.nvim_buf_set_var(buf, 'code_action_result', items)
  vim.api.nvim_win_set_option(win, 'winhighlight', 'Normal:NormalFloat')
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, title)
  vim.api.nvim_buf_set_keymap(buf, 'n', '<CR>', string.format(fmt, win), {silent=true})
  vim.api.nvim_buf_set_keymap(buf, 'n', '<ESC>', ':lua vim.api.nvim_win_close(' .. win .. ', true)<CR>' , {silent=true})
  vim.api.nvim_buf_set_keymap(buf, 'n', '<C-n>', '<DOWN>' , {silent=true})
  vim.api.nvim_buf_set_keymap(buf, 'n', '<C-p>', '<UP>' , {silent=true})
end

function M.setup()
  vim.ui.select = float_ui_select
end

return M
