local M = {}

function M.trim(text)
  return tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

function M.project_root(bufnr)
  local state = rawget(_G, "laravel_nvim")
  if state and type(state.project_root) == "string" and state.project_root ~= "" then
    return state.project_root
  end

  bufnr = bufnr or 0
  local root = vim.fs.root(bufnr, { "artisan", "composer.json" })
  if root and vim.fn.filereadable(root .. "/artisan") == 1 then
    return root
  end

  return nil
end

function M.path_exists(path)
  return type(path) == "string" and vim.fn.filereadable(path) == 1
end

function M.open_path(path)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
end

function M.studly(segment)
  local result = {}
  segment = tostring(segment or ""):gsub("[_%-%s]+", " ")
  for part in segment:gmatch("%S+") do
    result[#result + 1] = part:sub(1, 1):upper() .. part:sub(2)
  end
  return table.concat(result, "")
end

function M.kebab(segment)
  return tostring(segment or "")
    :gsub("([%u]+)([%u][%l])", "%1-%2")
    :gsub("([%l%d])([%u])", "%1-%2")
    :gsub("[_%s]+", "-")
    :lower()
end

function M.extract_quoted_strings(text)
  local strings = {}
  local index = 1
  text = tostring(text or "")

  while index <= #text do
    local char = text:sub(index, index)
    if char == "'" or char == '"' then
      local quote = char
      local cursor = index + 1
      local value = {}

      while cursor <= #text do
        local current = text:sub(cursor, cursor)
        if current == "\\" and cursor < #text then
          value[#value + 1] = text:sub(cursor + 1, cursor + 1)
          cursor = cursor + 2
        elseif current == quote then
          break
        else
          value[#value + 1] = current
          cursor = cursor + 1
        end
      end

      if cursor <= #text then
        strings[#strings + 1] = table.concat(value)
        index = cursor + 1
      else
        index = cursor
      end
    else
      index = index + 1
    end
  end

  return strings
end

function M.cursor_context(radius)
  radius = radius or 5
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1]
  local col = cursor[2] + 1
  local bufnr = vim.api.nvim_get_current_buf()
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local start_line = math.max(1, row - radius)
  local end_line = math.min(line_count, row + radius)
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)

  local cursor_offset = 0
  for lnum = start_line, row - 1 do
    cursor_offset = cursor_offset + #lines[lnum - start_line + 1] + 1
  end
  cursor_offset = cursor_offset + col

  return table.concat(lines, "\n"), cursor_offset
end

function M.view_candidates(root, name)
  name = M.trim(name)
  if name == "" then
    return {}
  end

  local package, view = name:match("^([%w_-]+)::(.+)$")
  if package and view then
    local view_rel = view:gsub("%.", "/")
    return {
      root .. "/resources/views/vendor/" .. package .. "/" .. view_rel .. ".blade.php",
      root .. "/resources/views/vendor/" .. package .. "/components/" .. view_rel .. ".blade.php",
      root .. "/resources/views/vendor/" .. package .. "/html/" .. view_rel .. ".blade.php",
    }
  end

  local view_rel = name:gsub("%.", "/")
  return {
    root .. "/resources/views/" .. view_rel .. ".blade.php",
    root .. "/resources/views/pages/" .. view_rel .. ".blade.php",
    root .. "/resources/views/livewire/" .. view_rel .. ".blade.php",
  }
end

function M.resolve_view(name, root)
  root = root or M.project_root(0)
  if not root then
    return nil
  end

  local candidates = M.view_candidates(root, name)
  for _, candidate in ipairs(candidates) do
    if M.path_exists(candidate) then
      return candidate, candidates
    end
  end

  return nil, candidates
end

return M
