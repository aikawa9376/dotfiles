local M = {}

-- Robustly get visual selection text:
-- Prefer reading the '< and '> marks directly if available; otherwise, fall back to yum
-- register-based yanking method (maintains user's registers).
function M.get_visual_selection()
  -- First try to use marks '< and '>
  local sp = vim.fn.getpos("'<")
  local ep = vim.fn.getpos("'>")
  -- sp and ep are tables: [bufnum, lnum, col, off]
  if sp and ep and sp[2] > 0 and ep[2] > 0 then
    local start_row, start_col = sp[2], sp[3]
    local end_row, end_col = ep[2], ep[3]
    if start_row > end_row or (start_row == end_row and start_col > end_col) then
      start_row, end_row = end_row, start_row
      start_col, end_col = end_col, start_col
    end
    local lines = vim.api.nvim_buf_get_lines(0, start_row - 1, end_row, false)
    if #lines == 0 then
      return ""
    end
    local last_line_len = #lines[#lines]
    if end_col > last_line_len then
      end_col = last_line_len
    end

    if #lines == 1 then
      return string.sub(lines[1], start_col, end_col)
    else
      lines[1] = string.sub(lines[1], start_col)
      lines[#lines] = string.sub(lines[#lines], 1, end_col)
      return table.concat(lines, "\n")
    end
  end

  -- Fallback to yank-to-register logic (preserve unnamed register)
  local ok, saved_reg = pcall(vim.fn.getreg, '"')
  local ok2, saved_regtype = pcall(vim.fn.getregtype, '"')

  local mode = vim.fn.mode()
  if mode:match("[vV\\x16]") then
    vim.cmd([[silent! normal! "zy]])
  else
    vim.cmd([[silent! normal! gv"zy]])
  end

  local content = vim.fn.getreg('z') or ""
  pcall(vim.fn.setreg, '"', saved_reg or "", saved_regtype or "")
  return content
end

return M
