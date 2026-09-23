-- Status rows are transient; retain section/path and selected hunk identity.
local M = {}
local function renderer(buf)
  if vim.bo[buf].filetype ~= 'fugitivestatus' then return end
  return (package.loaded['git.features.status_renderer'] or package.loaded['features.status_renderer'])
end

local function file_range(lines, row, first, last)
  local next_line, start_line, end_line
  for i = row + 1, last do
    local line = lines[i]
    local new_start = line:match('^@@ %-%d+,?%d* %+(%d+)')
    if new_start then next_line = tonumber(new_start)
    elseif line:match('^@@ new file:') then next_line = 1
    elseif next_line then
      local prefix = line:sub(1, 1)
      if i >= first then
        if prefix ~= '+' and prefix ~= ' ' then return end
        start_line, end_line = start_line or next_line, next_line
      end
      if prefix == '+' or prefix == ' ' then next_line = next_line + 1 end
    end
    if i >= first and (line:match('^@@') or not next_line) then return end
  end
  return start_line, end_line
end

function M.reference(source)
  if not source.path then return 'Git status (' .. source.section .. ')' end
  local reference = '@' .. source.path
  if source.start_line and source.end_line then
    reference = reference .. ':' .. source.start_line
    if source.end_line ~= source.start_line then reference = reference .. '-' .. source.end_line end
  end
  return reference
end

function M.capture(buf, root, first, last)
  local model = renderer(buf)
  if not model or not first then return end
  local entry = model.entry_at(buf, first)
  if not entry then return end
  local finish = model.entry_at(buf, last)
  if not finish or finish.section ~= entry.section or finish.path ~= entry.path then return end
  local row = model.entry_row(buf, first) or first
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local hunk
  for i = first, row + 1, -1 do
    if lines[i]:match('^@@') then hunk = lines[i]; break end
  end
  local start_line, end_line
  if first > row and entry.section ~= 'staged' then
    start_line, end_line = file_range(lines, row, first, last)
  end
  return { kind = 'status', root = vim.b[buf].fugitive_work_tree or root,
    git_dir = vim.b[buf].git_dir, path = entry.path, section = entry.section,
    start_line = start_line, end_line = end_line,
    status = true, header = entry.header == true, hunk = hunk,
    selection = first > row and vim.api.nvim_buf_get_lines(buf, first - 1, last, false) or nil,
    revision = entry.section == 'staged' and ':0' or 'working-tree', side = 'status',
    name = vim.api.nvim_buf_get_name(buf), filetype = 'git' }
end

function M.range(buf, source)
  local model = renderer(buf)
  if not model or vim.b[buf].fugitive_work_tree ~= source.root then return end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for row = 1, #lines do
    local entry = model.entry_at(buf, row)
    if entry and entry.section == source.section and entry.path == source.path
      and (entry.header == true) == source.header and (entry.header or model.entry_row(buf, row) == row) then
      if not source.selection then return row, row end
      local hunk, matched, matched_end
      for i = row + 1, #lines do
        local current = model.entry_at(buf, i)
        if not current or current.header or current.section ~= source.section or current.path ~= source.path then break end
        if lines[i]:match('^@@') then hunk = lines[i] end
        if hunk == source.hunk and lines[i] == source.selection[1] then
          local equal = true
          for j, text in ipairs(source.selection) do
            if lines[i + j - 1] ~= text then equal = false; break end
          end
          if equal then
            if matched then return row, row end -- ambiguous selection: keep the file anchor
            matched, matched_end = i, i + #source.selection - 1
          end
        end
      end
      return matched or row, matched_end or row
    end
  end
end

function M.jump(source)
  local status = (package.loaded['git.features.status'] or package.loaded['features.status'])
  if not status then return false end
  local buf = status.open({ work_tree = source.root, split = true, focus = false })
  if not buf then return false end
  local function focus()
    if not vim.api.nvim_buf_is_loaded(buf) then return false end
    local row = M.range(buf, source)
    if not row then return false end
    if source.selection then
      renderer(buf).update_diff(buf, row, 'show')
      row = M.range(buf, source) or row
    end
    local win = vim.fn.bufwinid(buf)
    if win ~= -1 then vim.api.nvim_win_set_cursor(win, { row, 0 }) end
    return true
  end
  if not focus() then
    local win, attempts = vim.fn.bufwinid(buf), 0
    local function retry()
      if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_get_current_win() ~= win
        or vim.api.nvim_win_get_buf(win) ~= buf then return end
      attempts = attempts + 1
      if not focus() and attempts < 100 then vim.defer_fn(retry, 50) end
    end
    vim.defer_fn(retry, 50)
  end
  return true
end
return M
