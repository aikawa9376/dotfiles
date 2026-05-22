local M = {}

function M.new(ctx)
  local is_markdown_fence = ctx.is_markdown_fence

  local function trim(text)
    return tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  end

  local function split_markdown_table_cells(line)
    if type(line) ~= "string" then
      return nil, nil
    end

    local prefix, trimmed = line:match("^(%s*)(.-)%s*$")
    if not trimmed or trimmed == "" then
      return nil, nil
    end
    if not trimmed:find("|", 1, true) then
      return nil, nil
    end

    local function pipe_is_escaped(text, idx)
      local backslashes = 0
      idx = idx - 1
      while idx >= 1 and text:sub(idx, idx) == "\\" do
        backslashes = backslashes + 1
        idx = idx - 1
      end
      return (backslashes % 2) == 1
    end

    if trimmed:sub(1, 1) == "|" then
      trimmed = trimmed:sub(2)
    end
    if trimmed:sub(-1) == "|" and not pipe_is_escaped(trimmed, #trimmed) then
      trimmed = trimmed:sub(1, -2)
    end

    local cells = {}
    local current = {}
    local escaped = false

    for idx = 1, #trimmed do
      local char = trimmed:sub(idx, idx)
      if escaped then
        current[#current + 1] = char
        escaped = false
      elseif char == "\\" then
        escaped = true
        current[#current + 1] = char
      elseif char == "|" then
        cells[#cells + 1] = trim(table.concat(current))
        current = {}
      else
        current[#current + 1] = char
      end
    end
    cells[#cells + 1] = trim(table.concat(current))

    if #cells < 2 then
      return nil, nil
    end
    return prefix, cells
  end

  local function is_markdown_table_separator(line, expected_columns)
    local _, cells = split_markdown_table_cells(line)
    if not cells or #cells < 2 then
      return false
    end
    if expected_columns and #cells ~= expected_columns then
      return false
    end

    for _, cell in ipairs(cells) do
      local normalized = trim(cell):gsub("%s+", "")
      if normalized == "" or not normalized:match("^:?-+:?$") then
        return false
      end
    end
    return true
  end

  local function render_table_cards(prefix, headers, rows)
    local rendered = {}
    local meta = {
      heading_rows = {},
    }
    prefix = prefix or ""

    for row_idx, row in ipairs(rows) do
      if row_idx > 1 then
        rendered[#rendered + 1] = ""
      end
      for col_idx, header in ipairs(headers) do
        local key = trim(header)
        if key == "" then
          key = string.format("Column %d", col_idx)
        end
        rendered[#rendered + 1] = string.format("%s- %s", prefix, key)
        meta.heading_rows[#rendered] = col_idx == 1 and "title" or "field"

        local value = tostring(row[col_idx] or "")
        local value_lines = vim.split(value, "\n", { plain = true })
        if #value_lines == 0 then
          value_lines = { "" }
        end
        for _, value_line in ipairs(value_lines) do
          rendered[#rendered + 1] = string.format("%s %s", prefix, value_line)
        end
      end
    end

    return rendered, meta
  end

  local function transform_markdown_tables(lines, layout)
    if layout ~= "card" then
      return lines, false, {}
    end

    lines = type(lines) == "table" and lines or {}
    local out = {}
    local meta = {
      heading_rows = {},
    }
    local changed = false
    local inside_fence = false
    local row = 1

    while row <= #lines do
      local line = lines[row]
      if is_markdown_fence(line) then
        inside_fence = not inside_fence
        out[#out + 1] = line
        row = row + 1
      elseif inside_fence then
        out[#out + 1] = line
        row = row + 1
      else
        local prefix, headers = split_markdown_table_cells(line)
        if headers and is_markdown_table_separator(lines[row + 1], #headers) then
          local rows = {}
          local cursor = row + 2
          while cursor <= #lines do
            local _, cells = split_markdown_table_cells(lines[cursor])
            if not cells or is_markdown_table_separator(lines[cursor], #headers) then
              break
            end
            while #cells < #headers do
              cells[#cells + 1] = ""
            end
            if #cells > #headers then
              cells = vim.list_slice(cells, 1, #headers)
            end
            rows[#rows + 1] = cells
            cursor = cursor + 1
          end

          if #rows > 0 then
            local base = #out
            local rendered, rendered_meta = render_table_cards(prefix, headers, rows)
            vim.list_extend(out, rendered)
            for rel_row, kind in pairs(rendered_meta.heading_rows or {}) do
              meta.heading_rows[base + rel_row] = kind
            end
            changed = true
            row = cursor
          else
            out[#out + 1] = line
            row = row + 1
          end
        else
          out[#out + 1] = line
          row = row + 1
        end
      end
    end

    return changed and out or lines, changed, changed and meta or {}
  end

  local function trailing_markdown_table_context(lines)
    lines = type(lines) == "table" and lines or {}

    local end_idx = #lines
    while end_idx > 0 and tostring(lines[end_idx] or "") == "" do
      end_idx = end_idx - 1
    end
    if end_idx <= 0 then
      return {
        state = "none",
        lines = {},
      }
    end

    local inside_fence = false
    local kinds = {}
    for idx = 1, end_idx do
      local line = lines[idx]
      if is_markdown_fence(line) then
        inside_fence = not inside_fence
        kinds[idx] = "fence"
      elseif inside_fence then
        kinds[idx] = "other"
      else
        local _, cells = split_markdown_table_cells(line)
        if cells then
          kinds[idx] = is_markdown_table_separator(line, #cells) and "separator" or "row"
        else
          kinds[idx] = "other"
        end
      end
    end

    if inside_fence then
      return {
        state = "none",
        lines = {},
      }
    end

    if kinds[end_idx] ~= "row" and kinds[end_idx] ~= "separator" then
      return {
        state = "none",
        lines = {},
      }
    end

    local start_idx = end_idx
    while start_idx > 1 and (kinds[start_idx - 1] == "row" or kinds[start_idx - 1] == "separator") do
      start_idx = start_idx - 1
    end

    local block_kinds = {}
    for idx = start_idx, end_idx do
      block_kinds[#block_kinds + 1] = kinds[idx]
    end

    local state = "none"
    if block_kinds[1] == "row" then
      if #block_kinds == 1 then
        state = "header"
      elseif block_kinds[2] == "separator" then
        state = #block_kinds == 2 and "separator" or "rows"
        for idx = 3, #block_kinds do
          if block_kinds[idx] ~= "row" then
            state = "none"
            break
          end
        end
      end
    end

    return {
      state = state,
      lines = state == "none" and {} or vim.list_slice(lines, start_idx, end_idx),
    }
  end

  return {
    split_markdown_table_cells = split_markdown_table_cells,
    is_markdown_table_separator = is_markdown_table_separator,
    transform_markdown_tables = transform_markdown_tables,
    trailing_markdown_table_context = trailing_markdown_table_context,
  }
end

return M
