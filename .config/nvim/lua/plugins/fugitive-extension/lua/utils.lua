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
  local result = vim.fn.FugitiveParse(vim.api.nvim_buf_get_name(bufnr))
  return result and result[1] or nil
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
