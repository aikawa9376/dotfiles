-- Pure selection of a committed file patch. Keep Git's quoted path headers.
local M = {}

local function bounds(lines, start)
  if not (lines[start] or ''):match('^@@ ') then return nil end
  local first = start
  while first > 1 and not lines[first]:match('^diff %-%-git ') do first = first - 1 end
  local header_end = first
  while header_end < start and not lines[header_end]:match('^@@ ') do header_end = header_end + 1 end
  local last = start + 1
  while last <= #lines and not lines[last]:match('^@@ ') and not lines[last]:match('^diff %-%-git ') do last = last + 1 end
  return first, header_end - 1, last - 1
end

function M.hunk(lines, start)
  local first, header_end, last = bounds(lines, start)
  if not first then return nil end
  local result = vim.list_slice(lines, first, header_end)
  vim.list_extend(result, vim.list_slice(lines, start, last))
  return result
end

-- Return a forward patch whose reverse removes only the selected changes.
-- Unselected additions become context; unselected deletions disappear. One
-- counted hunk avoids overlapping one-line hunks and preserves EOF markers.
function M.selection(lines, start, selected_first, selected_last, selected_lines)
  local first, header_end, last = bounds(lines, start)
  if not first or selected_first < start or selected_last > last then return nil end
  local new_start = tonumber(lines[start]:match('^@@ %-%d+,?%d* %+(%d+),?%d* @@'))
  if not new_start then return nil end
  local body, old_count, new_count, changed, kept = {}, 0, 0, 0, false
  for row = start + 1, last do
    local line = lines[row]
    local selected = selected_lines and selected_lines[row]
      or (not selected_lines and row >= selected_first and row <= selected_last)
    local kind = line:sub(1, 1)
    if kind == '+' or kind == '-' then
      kept = selected or kind == '+'
      if selected then changed = changed + 1
      elseif kind == '+' then line, kind = ' ' .. line:sub(2), ' ' end
    elseif kind == ' ' then kept = true
    elseif kind ~= '\\' then return nil end
    if kept then
      body[#body + 1] = line
      if kind == ' ' or kind == '-' then old_count = old_count + 1 end
      if kind == ' ' or kind == '+' then new_count = new_count + 1 end
    end
  end
  if changed == 0 then return nil end
  -- A former EOF deletion can become an interior line after partial reversal.
  -- Keep a no-newline marker only when that line is still last on its side.
  local old_last, new_last
  for row, line in ipairs(body) do
    local kind = line:sub(1, 1)
    if kind == ' ' or kind == '-' then old_last = row end
    if kind == ' ' or kind == '+' then new_last = row end
  end
  for row = #body, 1, -1 do
    if body[row]:sub(1, 1) == '\\' then
      local previous = row - 1
      local kind = body[previous]:sub(1, 1)
      if (kind == '-' and previous ~= old_last) or (kind == '+' and previous ~= new_last)
        or (kind == ' ' and (previous ~= old_last or previous ~= new_last)) then
        table.remove(body, row)
      end
    end
  end
  local old_start = new_start
  if new_count == 0 and old_count > 0 then old_start = new_start + 1
  elseif old_count == 0 and new_count > 0 then old_start = new_start - 1 end

  local path, created, deleted
  for row = first, header_end do
    created = created or lines[row]:match('^new file mode ') ~= nil
    deleted = deleted or lines[row]:match('^deleted file mode ') ~= nil
    local value = lines[row]:match('^%+%+%+ (.*)$')
    if value and value ~= '/dev/null' then path = value end
  end
  if not path then
    for row = first, header_end do
      local value = lines[row]:match('^%-%-%- (.*)$')
      if value and value ~= '/dev/null' then path = value end
    end
  end
  if not path then return nil end
  path = path:gsub('\t.*$', '')
  local old_path = path:gsub('^("?)b/', '%1a/')
  local new_path = path:gsub('^("?)a/', '%1b/')
  local result = {}
  for row = first, header_end do
    local line = lines[row]
    if line:match('^diff %-%-git ') then
      -- Text selection on a renamed file changes its current path only.
      result[#result + 1] = 'diff --git ' .. old_path .. ' ' .. new_path
    elseif line:match('^%-%-%- ') then
      result[#result + 1] = '--- ' .. (created and old_count == 0 and '/dev/null' or old_path)
    elseif line:match('^%+%+%+ ') then
      result[#result + 1] = '+++ ' .. (deleted and new_count == 0 and '/dev/null' or new_path)
    elseif line:match('^new file mode ') and old_count == 0 then result[#result + 1] = line
    elseif line:match('^deleted file mode ') and new_count == 0 then result[#result + 1] = line end
  end
  result[#result + 1] = string.format('@@ -%d,%d +%d,%d @@', old_start, old_count, new_start, new_count)
  vim.list_extend(result, body)
  return result
end

return M
