local M = {}

local function set_extmark()
  local bnr = vim.fn.bufnr('%')
  local count_id = vim.api.nvim_create_namespace('searchcount')
  local cursor_id = vim.api.nvim_create_namespace('corsorcount')
  local s_count = vim.fn.searchcount()
  s_count = '-> (' .. s_count['current'] .. '/' .. s_count['total'] .. ')'

  local line_num = vim.fn.line(".") - 1
  local col_num = vim.fn.col(".") - 1

  local text_opts = {
    end_line = 0,
    id = 1,
    virt_text = {{s_count, "DiagnosticError"}},
    virt_text_pos = 'eol',
  }
  local cursor_opts =  {
    end_col = col_num + 1,
    id = 2,
    hl_group = 'Cursor'
  }
  vim.api.nvim_buf_set_extmark(bnr, cursor_id, line_num, col_num, cursor_opts)
  return vim.api.nvim_buf_set_extmark(bnr, count_id, line_num, col_num, text_opts)
end

M.search_count = function (target)
  if not pcall(vim.api.nvim_exec, 'normal! ' .. target, true) then
    print('search not found')
    return
  end
  set_extmark()
  vim.api.nvim_exec('redraw', true)
  local key = vim.fn.nr2char(vim.fn.getchar())
  while key == "n" or key == 'N' do
    if key == "n" then
      vim.api.nvim_exec('normal! n', true)
      set_extmark()
    elseif key == "N" then
      vim.api.nvim_exec('normal! N', true)
      set_extmark()
    end
    vim.api.nvim_exec('redraw', true)
    key = vim.fn.nr2char(vim.fn.getchar())
  end
  vim.fn.feedkeys(key)
  vim.api.nvim_exec('nohl', true)
  vim.api.nvim_buf_clear_highlight(vim.fn.bufnr('%'), 0, 0, -1)
end

return M
