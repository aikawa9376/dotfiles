local M = {}

-- Encode semantic keys as lines for xdiff. IDs preserve arbitrary key bytes,
-- including NUL/newline characters, without relying on collision-prone hashes.
local function encode_keys(keys, intern)
  local ids = intern.ids
  local encoded = {}
  for i, key in ipairs(keys) do
    if not ids[key] then
      intern.count = intern.count + 1
      ids[key] = tostring(intern.count) .. '\n'
    end
    encoded[i] = ids[key]
  end
  return table.concat(encoded)
end

function M.apply(bufnr, start_row, end_row, new_lines, line_keys)
  local start_idx = start_row - 1
  local old_lines = vim.api.nvim_buf_get_lines(bufnr, start_idx, end_row, false)
  if vim.deep_equal(old_lines, new_lines) then return end

  local ids = { ids = {}, count = 0 }
  local old_keys = encode_keys(line_keys(old_lines), ids)
  local new_keys = encode_keys(line_keys(new_lines), ids)
  local hunks = vim.diff(old_keys, new_keys, { result_type = 'indices', algorithm = 'minimal' })

  -- Apply edits from the bottom so earlier row indices remain valid. Matched
  -- keys keep their rows/extmarks even when their displayed text changes.
  local function rewrite_matched(old_end, new_end, count)
    for offset = 0, count - 1 do
      local old_row, new_row = old_end - offset, new_end - offset
      if old_lines[old_row] ~= new_lines[new_row] then
        local row = start_idx + old_row - 1
        vim.api.nvim_buf_set_text(bufnr, row, 0, row, #old_lines[old_row], { new_lines[new_row] })
      end
    end
  end

  local old_end, new_end = #old_lines, #new_lines
  for i = #hunks, 1, -1 do
    local hunk = hunks[i]
    -- A zero-length side points to the row before the insertion/deletion.
    local old_start = hunk[1] + (hunk[2] == 0 and 1 or 0)
    local new_start = hunk[3] + (hunk[4] == 0 and 1 or 0)
    rewrite_matched(old_end, new_end, old_end - old_start - hunk[2] + 1)
    local replacement = {}
    for row = new_start, new_start + hunk[4] - 1 do replacement[#replacement + 1] = new_lines[row] end
    vim.api.nvim_buf_set_lines(bufnr, start_idx + old_start - 1,
      start_idx + old_start + hunk[2] - 1, false, replacement)
    old_end, new_end = old_start - 1, new_start - 1
  end
  rewrite_matched(old_end, new_end, old_end)
end

return M
