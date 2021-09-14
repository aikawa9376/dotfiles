local M = {}

-- rename settings
function M.dorename(win)
  local new_name = vim.trim(vim.fn.getline('.'))
  vim.api.nvim_win_close(win, true)
  vim.lsp.buf.rename(new_name)
end

function M.rename()
  local opts = {
    relative = 'cursor', row = 1,
    col = 0, width = 30,
    height = 1, style = 'minimal'
  }
  local cword = vim.fn.expand('<cword>')
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, opts)
  local fmt =  '<cmd>lua require("lsp.configs.rename").dorename(%d)<CR>'
  vim.api.nvim_win_set_option(win, 'winhighlight', 'Normal:NormalFloat')

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {cword})
  vim.api.nvim_buf_set_keymap(buf, 'n', '<CR>', string.format(fmt, win), {silent=true})
  vim.api.nvim_buf_set_keymap(buf, 'n', '<ESC>', ':lua vim.api.nvim_win_close(win, true)<CR>' , {silent=true})
  vim.api.nvim_win_set_cursor(win, {1, #cword})
end

return M
