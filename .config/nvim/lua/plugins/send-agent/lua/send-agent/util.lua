local M = {}

local function normalize_text(text)
  -- Normalize CRLF -> LF and ensure trailing newline
  local s = tostring(text or "")
  s = s:gsub("\r\n", "\n")
  if not s:match("\n$") then
    s = s .. "\n"
  end
  return s
end

local function contains_enter_key(keys)
  -- Detect whether a list/string of keys contains an "enter"/submit equivalent,
  -- e.g. "C-m", "<CR>", "Enter", "Return".
  if not keys then return false end
  if type(keys) == "string" then keys = { keys } end
  if type(keys) ~= "table" then return false end
  for _, k in ipairs(keys) do
    local s = tostring(k)
    local ls = s:lower()
    if s == "C-m" or s == "Enter" or s == "<CR>" or s == "\r" or s == "Return" or ls == "<cr>" or ls == "<c-m>" then
      return true
    end
  end
  return false
end

M.normalize_text = normalize_text
M.contains_enter_key = contains_enter_key

-- Robustly get visual selection text:
-- Prefer reading the '< and '> marks directly if available; otherwise, fall back to a
-- yank-based selection while keeping the user's unnamed register intact.
function M.get_visual_selection()
  -- First try to use marks '< and '>'
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
  local _, saved_reg = pcall(vim.fn.getreg, '"')
  local _, saved_regtype = pcall(vim.fn.getregtype, '"')

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

function M.git_root_for_path(path)
  path = path or vim.api.nvim_buf_get_name(0)
  if not path or path == "" then path = vim.fn.getcwd() end
  local cwd = vim.fn.fnamemodify(path, ":p:h")
  local cmd = "git -C " .. vim.fn.shellescape(cwd) .. " rev-parse --show-toplevel 2>/dev/null"
  local ok, out = pcall(vim.fn.systemlist, cmd)
  if ok and out and #out > 0 and out[1] and out[1] ~= "" then
    return out[1]
  end
  return nil
end

function M.git_branch_for_path(path)
  path = path or vim.api.nvim_buf_get_name(0)
  if not path or path == "" then path = vim.fn.getcwd() end
  local cwd = vim.fn.fnamemodify(path, ":p:h")
  local cmd = "git -C " .. vim.fn.shellescape(cwd) .. " rev-parse --abbrev-ref HEAD 2>/dev/null"
  local ok, out = pcall(vim.fn.systemlist, cmd)
  if ok and out and #out > 0 and out[1] and out[1] ~= "" then
    return out[1]
  end
  return nil
end

return M