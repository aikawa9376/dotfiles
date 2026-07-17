local M = {}
local TextRef = require("lazyagent.acp.text_ref")

local function read_ref(ref)
  if type(ref) ~= "table" or not ref.path or vim.fn.filereadable(ref.path) ~= 1 then
    return ""
  end
  local ok, lines
  if ref.end_line then
    ok, lines = pcall(vim.fn.readfile, ref.path, "", tonumber(ref.end_line))
  else
    ok, lines = pcall(vim.fn.readfile, ref.path)
  end
  if not ok then return "" end
  if ref.start_line then
    local sliced = {}
    for index = math.max(1, tonumber(ref.start_line) or 1), #lines do
      sliced[#sliced + 1] = lines[index]
    end
    lines = sliced
  end
  return table.concat(lines, "\n")
end

local function add_text(parts, value)
  if type(value) == "string" and value ~= "" then
    parts[#parts + 1] = value
  end
end

local function preview(text, query)
  text = tostring(text or ""):gsub("%s+", " ")
  local start = text:lower():find(query:lower(), 1, true) or 1
  local left = math.max(1, start - 55)
  local value = text:sub(left, left + 150)
  if left > 1 then value = "..." .. value end
  if left + 150 < #text then value = value .. "..." end
  return value
end

function M.search(conversation, tools, query, opts)
  opts = opts or {}
  query = vim.trim(tostring(query or ""))
  if query == "" then return {} end
  local load_ref = opts.read_ref or read_ref
  local custom_reader = opts.read_ref ~= nil
  local needle = query:lower()
  local results = {}

  local function match_parts(parts, refs)
    local haystack = table.concat(parts, "\n")
    if haystack:lower():find(needle, 1, true) then
      return preview(haystack, query)
    end
    for _, ref in ipairs(refs) do
      if custom_reader then
        local ref_text = load_ref(ref)
        if ref_text:lower():find(needle, 1, true) then
          return preview(ref_text, query)
        end
      else
        local ref_preview = TextRef.search(ref, query)
        if ref_preview then
          return ref_preview
        end
      end
    end
    return nil
  end

  for _, item in ipairs(conversation or {}) do
    local parts = {}
    add_text(parts, item.title)
    add_text(parts, item.heading)
    add_text(parts, item.summary)
    add_text(parts, item.body)
    for _, chunk in ipairs(item.body_chunks or {}) do add_text(parts, chunk) end
    local match_preview = match_parts(parts, { item.body_ref })
    if match_preview then
      results[#results + 1] = {
        target = "conversation",
        kind = item.kind or "message",
        id = item.id,
        title = item.title or item.heading or item.kind or "Message",
        preview = match_preview,
      }
    end
  end

  for _, entry in ipairs(tools or {}) do
    local parts = {}
    add_text(parts, entry.title)
    add_text(parts, entry.summary)
    add_text(parts, entry.rendered_content)
    add_text(parts, entry.rendered_raw_output)
    local refs = {}
    if entry.rendered_content_ref then refs[#refs + 1] = entry.rendered_content_ref end
    if entry.rendered_raw_output_ref then refs[#refs + 1] = entry.rendered_raw_output_ref end
    local match_preview = match_parts(parts, refs)
    if match_preview then
      results[#results + 1] = {
        target = "tool",
        kind = "tool",
        tool_call_id = entry.toolCallId,
        title = entry.title or entry.toolCallId or "Tool",
        preview = match_preview,
      }
    end
  end

  return results
end

return M
