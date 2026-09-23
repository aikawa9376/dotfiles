-- Optional LazyAgent adapter. It does not load LazyAgent during commit browsing.
local M = {}
local function api() return require('git.features.commit') end
function M.capture(buf, first, last)
  local model = api().model(buf)
  if not model or not first then return nil end
  local entry, info = api().entry_at(buf, first)
  local last_entry = api().entry_at(buf, last or first)
  if not entry or last_entry ~= entry then return nil end
  local source = { kind = 'fugitive', root = model.root, git_dir = vim.b[buf].git_dir,
    path = entry.path, revision = model.hash, review_commit = model.hash, side = 'b',
    custom_commit = true, parent_index = model.parent_index, inline_diff = true,
    name = vim.api.nvim_buf_get_name(buf), filetype = vim.filetype.match({ filename = entry.path }) or '',
    header = info.header == true }
  source.selection = not info.header and vim.api.nvim_buf_get_lines(buf, first - 1, last or first, false) or nil
  local patch = require('git.features.commit_model').patch(model, entry)
  local hunk
  if info.patch_row then
    for i = info.patch_row, 1, -1 do if patch[i]:match('^@@') then hunk = i; break end end
  end
  if hunk then
    source.hunk = patch[hunk]
    local side
    for _, line in ipairs(source.selection) do
      local prefix = line:sub(1, 1)
      if prefix ~= '+' and prefix ~= '-' and prefix ~= ' ' then side = 'mixed'; break end
      local current = prefix == '-' and 'a' or prefix == '+' and 'b' or nil
      if current and side and side ~= current then side = 'mixed'; break end
      side = current or side
    end
    if side ~= 'mixed' then
      source.side = side or 'b'
      local old, new = patch[hunk]:match('^@@ %-(%d+),?%d* %+(%d+)')
      old, new = tonumber(old), tonumber(new)
      for i = hunk + 1, info.patch_row - 1 do
        local prefix = patch[i]:sub(1, 1)
        if prefix == ' ' or prefix == '-' then old = old + 1 end
        if prefix == ' ' or prefix == '+' then new = new + 1 end
      end
      source.start_line = source.side == 'a' and old or new
      source.end_line = source.start_line + #source.selection - 1
    end
  end
  if source.side == 'a' then
    source.path = entry.old_path or entry.path
    source.revision = model.base
  end
  source.section = entry.path -- displayed path, also for deleted/renamed old-side notes
  local blob = require('git.features.commit_model').git(model.root, { 'rev-parse', '--verify', source.revision .. ':' .. source.path })
  if blob then source.blob = vim.trim(blob) end
  return source
end
function M.range(buf, source)
  local model = api().model(buf)
  if not model or model.root ~= source.root or model.hash ~= source.review_commit
    or model.parent_index ~= (source.parent_index or 1) then return end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local header, hunk
  for row = 1, #lines do
    local entry, info = api().entry_at(buf, row)
    if entry and entry.path == (source.section or source.path) then
      if info.header then header = row end
      if lines[row]:match('^@@') then hunk = lines[row] end
      if source.selection and hunk == source.hunk then
        local equal = true
        for i, line in ipairs(source.selection) do if lines[row + i - 1] ~= line then equal = false; break end end
        if equal then return row, row + #source.selection - 1 end
      end
    end
  end
  return header, header
end
function M.jump(source)
  local buf = api().open({ work_tree = source.root, revision = source.review_commit, parent = source.parent_index, split = true })
  if not buf then return false end
  api().expand_file(buf, source.section or source.path)
  local row = M.range(buf, source)
  if row then vim.api.nvim_win_set_cursor(0, { row, 0 }) end
  return row ~= nil
end
return M
