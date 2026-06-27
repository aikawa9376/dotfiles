local completion_utils = require("blink_extension.completion.utils")

local M = {}

local function line_to_cursor(ctx)
  local line = type(ctx) == "table" and ctx.line or ""
  local cursor = type(ctx) == "table" and ctx.cursor or nil
  local col = type(cursor) == "table" and cursor[2] or 0

  if type(line) ~= "string" then
    return ""
  end

  if type(col) ~= "number" or col < 0 then
    col = 0
  end

  return line:sub(1, col)
end

local japanese_context_punctuation = {
  ["."] = true,
  [","] = true,
  ["!"] = true,
  ["?"] = true,
  ["。"] = true,
  ["、"] = true,
  ["！"] = true,
  ["？"] = true,
  ["．"] = true,
  ["，"] = true,
}

local function is_punctuation_after_japanese(text)
  local chars = completion_utils.split_chars(text)
  local last = chars[#chars]
  if not japanese_context_punctuation[last] then
    return false
  end

  chars[#chars] = nil
  return completion_utils.extract_trailing_japanese(table.concat(chars)) ~= ""
end

function M.is_japanese_completion_context(ctx)
  local text = line_to_cursor(ctx)
  if completion_utils.extract_trailing_japanese(text) ~= "" then
    return true
  end

  return is_punctuation_after_japanese(text)
end

function M.filter_ascii_completion_items(items)
  return vim.tbl_filter(function(item)
    return type(item) == "table"
      and type(item.label) == "string"
      and completion_utils.is_ascii(item.label)
  end, items)
end

return M
