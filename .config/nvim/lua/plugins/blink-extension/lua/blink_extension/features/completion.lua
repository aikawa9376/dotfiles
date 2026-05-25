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

function M.is_japanese_completion_context(ctx)
  return completion_utils.extract_trailing_japanese(line_to_cursor(ctx)) ~= ""
end

function M.filter_ascii_completion_items(items)
  return vim.tbl_filter(function(item)
    return type(item) == "table"
      and type(item.label) == "string"
      and completion_utils.is_ascii(item.label)
  end, items)
end

return M
