local M = {}

local diff_fn = vim.text and vim.text.diff or vim.diff

local function utf8_chars(str)
  local chars = {}
  local byte_positions = vim.str_utf_pos(str)
  table.insert(byte_positions, #str + 1)

  for i = 1, #byte_positions - 1 do
    local start_byte = byte_positions[i]
    local end_byte = byte_positions[i + 1]
    chars[#chars + 1] = {
      text = str:sub(start_byte, end_byte - 1),
      byte_pos = start_byte - 1,
    }
  end

  return chars
end

function M.normalize_lines(value)
  if type(value) == "table" then
    return vim.deepcopy(value)
  end

  local text = tostring(value or ""):gsub("\r\n", "\n")
  local lines = vim.split(text, "\n", { plain = true })
  if #lines > 0 and lines[#lines] == "" then
    table.remove(lines, #lines)
  end
  return lines
end

function M.language_from_path(path)
  path = tostring(path or "")
  if path == "" then
    return "text"
  end

  local ok, detected = pcall(vim.filetype.match, { filename = path })
  if ok and type(detected) == "string" and detected ~= "" then
    return detected
  end

  local ext = path:match("%.([%w_+-]+)$")
  if ext and ext ~= "" then
    return ext
  end

  return "text"
end

function M.filter_unchanged_lines(old_lines, new_lines)
  old_lines = M.normalize_lines(old_lines)
  new_lines = M.normalize_lines(new_lines)

  local result = { old_lines = {}, new_lines = {}, pairs = {} }
  local old_string = table.concat(old_lines, "\n")
  local new_string = table.concat(new_lines, "\n")
  if old_string == new_string then
    return result
  end

  local patch = diff_fn(old_string, new_string, {
    algorithm = "histogram",
    result_type = "indices",
    ctxlen = 0,
  })

  for _, hunk in ipairs(patch or {}) do
    local start_a, count_a, start_b, count_b = unpack(hunk)
    local pair_count = math.min(count_a, count_b)

    for i = 0, pair_count - 1 do
      local old_line = old_lines[start_a + i]
      local new_line = new_lines[start_b + i]
      if old_line ~= new_line then
        result.old_lines[#result.old_lines + 1] = old_line
        result.new_lines[#result.new_lines + 1] = new_line
        result.pairs[#result.pairs + 1] = {
          old_idx = start_a + i,
          new_idx = start_b + i,
          old_line = old_line,
          new_line = new_line,
        }
      end
    end

    for i = pair_count, count_a - 1 do
      local old_line = old_lines[start_a + i]
      result.old_lines[#result.old_lines + 1] = old_line
      result.pairs[#result.pairs + 1] = {
        old_idx = start_a + i,
        new_idx = nil,
        old_line = old_line,
        new_line = nil,
      }
    end

    for i = pair_count, count_b - 1 do
      local new_line = new_lines[start_b + i]
      result.new_lines[#result.new_lines + 1] = new_line
      result.pairs[#result.pairs + 1] = {
        old_idx = nil,
        new_idx = start_b + i,
        old_line = nil,
        new_line = new_line,
      }
    end
  end

  return result
end

function M.find_inline_change(old_line, new_line)
  old_line = tostring(old_line or "")
  new_line = tostring(new_line or "")
  if old_line == new_line then
    return nil
  end

  local old_chars = utf8_chars(old_line)
  local new_chars = utf8_chars(new_line)
  local prefix_chars = 0
  local min_len = math.min(#old_chars, #new_chars)

  for i = 1, min_len do
    if old_chars[i].text == new_chars[i].text then
      prefix_chars = i
    else
      break
    end
  end

  local suffix_chars = 0
  for i = 1, min_len - prefix_chars do
    local old_char = old_chars[#old_chars - i + 1]
    local new_char = new_chars[#new_chars - i + 1]
    if old_char.text == new_char.text then
      suffix_chars = i
    else
      break
    end
  end

  local old_start = 0
  local old_end = 0
  local new_start = 0
  local new_end = 0

  if prefix_chars > 0 then
    local old_prefix = old_chars[prefix_chars]
    local new_prefix = new_chars[prefix_chars]
    old_start = old_prefix.byte_pos + #old_prefix.text
    new_start = new_prefix.byte_pos + #new_prefix.text
  end

  local old_suffix_idx = #old_chars - suffix_chars
  if old_suffix_idx > 0 then
    local suffix = old_chars[old_suffix_idx]
    old_end = suffix.byte_pos + #suffix.text
  end

  local new_suffix_idx = #new_chars - suffix_chars
  if new_suffix_idx > 0 then
    local suffix = new_chars[new_suffix_idx]
    new_end = suffix.byte_pos + #suffix.text
  end

  if old_start >= old_end and new_start >= new_end then
    return nil
  end

  return {
    old_start = old_start,
    old_end = old_end,
    new_start = new_start,
    new_end = new_end,
  }
end

function M.format_diff_item(item, opts)
  opts = opts or {}
  item = type(item) == "table" and item or {}

  local old_lines = M.normalize_lines(item.oldText or item.old_text)
  local new_lines = M.normalize_lines(item.newText or item.new_text)
  local filtered = M.filter_unchanged_lines(old_lines, new_lines)
  local lines = {}
  local path = tostring(item.path or item.filePath or "")
  local lang = opts.lang or M.language_from_path(path)

  if path ~= "" and opts.include_path ~= false then
    lines[#lines + 1] = "Path: " .. path
  end

  lines[#lines + 1] = "```" .. lang

  if #filtered.pairs == 0 then
    if #new_lines > 0 then
      for _, line in ipairs(new_lines) do
        lines[#lines + 1] = "+ " .. line
      end
    elseif #old_lines > 0 then
      for _, line in ipairs(old_lines) do
        lines[#lines + 1] = "- " .. line
      end
    end
  else
    for _, pair in ipairs(filtered.pairs) do
      if pair.old_line ~= nil then
        lines[#lines + 1] = "- " .. pair.old_line
      end
      if pair.new_line ~= nil then
        lines[#lines + 1] = "+ " .. pair.new_line
      end
    end
  end

  lines[#lines + 1] = "```"
  return lines
end

return M
