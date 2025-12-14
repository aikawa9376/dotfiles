local M = {}

---@return string|nil
function M.get_filepath_at_cursor(bufnr)
  local current_line = vim.api.nvim_win_get_cursor(0)[1]
  for lnum = current_line, 1, -1 do
    local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
    if line then
      -- For fugitive status buffer
      local status_match = line:match('^[MADRCU?!][MADRCU?!]? (.+)$')
      if status_match then
        return status_match
      end
      -- For git commit buffer
      local commit_match = line:match('^diff %-%-git [ab]/(.+) [ab]/')
      if commit_match then
        return commit_match
      end
    end
  end
end

---@return string|nil
function M.get_commit(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local result = vim.fn.FugitiveParse(vim.api.nvim_buf_get_name(bufnr))
  return result and result[1] or nil
end

---@param win integer window id
---@param bufnr integer buffer number
function M.setup_flog_window(win, bufnr)
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].cursorline = false
  vim.wo[win].winhighlight = 'NormalNC:Normal'

  -- qでFlogウィンドウを閉じる
  vim.keymap.set('n', 'q', function()
    if vim.g.flog_win and vim.api.nvim_win_is_valid(vim.g.flog_win) then
      vim.api.nvim_win_close(vim.g.flog_win, true) -- Flogウィンドウを閉じる
      vim.g.flog_win = nil -- グローバル変数をクリア
      vim.g.flog_bufnr = nil -- グローバル変数をクリア
    end
  end, { buffer = bufnr, nowait = true, silent = true })
end

---@param flog_bufnr integer
---@param flog_win integer
---@param commit_sha string
function M.highlight_flog_commit(flog_bufnr, flog_win, commit_sha)
  if not (flog_win and vim.api.nvim_win_is_valid(flog_win) and flog_bufnr and vim.api.nvim_buf_is_valid(flog_bufnr)) then
    return
  end
  if not commit_sha or commit_sha == "" then
    return
  end

  local ns_id = vim.api.nvim_create_namespace('FlogHighlight')
  vim.api.nvim_buf_clear_namespace(flog_bufnr, ns_id, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(flog_bufnr, 0, -1, false)
  for idx, line in ipairs(lines) do
    if line:match(commit_sha:sub(1, 7)) then
      vim.api.nvim_buf_set_extmark(flog_bufnr, ns_id, idx - 1, 0, {
        end_col = #line,
        hl_group = 'Search',
        hl_mode = 'combine',
      })
      vim.api.nvim_win_call(flog_win, function()
        vim.api.nvim_win_set_cursor(flog_win, { idx, 0 })
        vim.cmd('normal! zt5k')
      end)
      break
    end
  end
end


local devicons_ok, devicons = pcall(require, 'nvim-web-devicons')

---@param filename string
---@return string, string
function M.get_devicon(filename)
  if not devicons_ok then
    return " ", "Normal"
  end
  local file_icon, hl = devicons.get_icon(filename, vim.fn.fnamemodify(filename, ":e"), { default = true })
  if file_icon then
    return file_icon, hl or "Normal"
  end
  return " ", "Normal"
end

return M
