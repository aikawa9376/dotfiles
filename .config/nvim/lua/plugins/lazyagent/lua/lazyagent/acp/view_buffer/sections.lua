local M = {}

local TRANSCRIPT_TRUNCATED_MARKER = "... earlier transcript omitted from buffer ..."
local SYNTHETIC_MARKDOWN_FENCE_CLOSE = " ```"

local function line_has_heading(line, heading)
  local needle = " " .. heading .. " "
  if line:find(needle, 1, true) then
    return true
  end
  local suffix = " " .. heading
  return line:sub(-#suffix) == suffix
end

local function replace_heading_token(line, heading, replacement)
  if type(line) ~= "string" then
    return line
  end
  local needle = " " .. heading .. " "
  if line:find(needle, 1, true) then
    return line:gsub(vim.pesc(needle), " " .. replacement .. " ", 1)
  end
  local suffix = " " .. heading
  if line:sub(-#suffix) == suffix then
    return line:sub(1, #line - #suffix) .. " " .. replacement
  end
  return line
end

local function line_has_assistant_heading(line)
  if line_has_heading(line, "Assistant") then
    return true
  end
  if type(line) ~= "string" then
    return false
  end
  line = line:gsub("^%s+", "")
  return line:match("^[─━╭┌ ]+" .. vim.pesc("󰭹") .. "%s") ~= nil
end

local function section_style_for_line(line)
  if line_has_heading(line, "User") then
    return "LazyAgentACPUserHeader"
  end
  if line_has_assistant_heading(line) then
    return "LazyAgentACPAssistantHeader"
  end
  if line_has_heading(line, "Thinking") then
    return "LazyAgentACPThinkingHeader"
  end
  if line_has_heading(line, "System") then
    return "LazyAgentACPSystemHeader"
  end
  if line_has_heading(line, "Error") then
    return "LazyAgentACPErrorHeader"
  end
  if line_has_heading(line, "Plan") then
    return "LazyAgentACPPlanHeader"
  end
  if line_has_heading(line, "Terminal") then
    return "LazyAgentACPTerminalHeader"
  end
  if line_has_heading(line, "Tool") or line_has_heading(line, "Edited") then
    return "LazyAgentACPToolHeader"
  end
  return "LazyAgentACPBorder"
end

local function line_has_tail(line)
  return line_has_heading(line, "User") or line_has_assistant_heading(line)
end

local function is_markdown_fence(line)
  return type(line) == "string" and line:match("^%s*```") ~= nil
end

local function code_block_target_row(lines, cur_row, forward)
  lines = type(lines) == "table" and lines or {}

  local openings = {}
  local inside_fence = false
  for row, line in ipairs(lines) do
    if is_markdown_fence(line) then
      if not inside_fence then
        local target = row
        if type(lines[row - 1]) == "string" and lines[row - 1]:match("^%s*Path:%s+") then
          target = row - 1
        end
        openings[#openings + 1] = target
      end
      inside_fence = not inside_fence
    end
  end

  if forward then
    for _, row in ipairs(openings) do
      if row > cur_row then
        return row
      end
    end
    return nil
  end

  for idx = #openings, 1, -1 do
    if openings[idx] < cur_row then
      return openings[idx]
    end
  end

  return nil
end

local SECTION_HEADINGS = {
  "User",
  "Assistant",
  "Thinking",
  "System",
  "Error",
  "Plan",
  "Terminal",
  "Tool",
  "Edited",
}

local FANCY_SECTION_LABELS = {
  User = "💬✨ User ✨💬",
  Assistant = "🤖🌈 Assistant 🌈🤖",
  Thinking = "🧠💭 Thinking 💭🧠",
  System = "🛸⚡ System ⚡🛸",
  Error = "🚨💥 Error 💥🚨",
  Plan = "🗺️🎀 Plan 🎀🗺️",
  Terminal = "🖥️🔥 Terminal 🔥🖥️",
  Tool = "🧰✨ Tool ✨🧰",
  Edited = "✍️🎉 Edited 🎉✍️",
}

local FANCY_POPUP_MARKDOWN_TITLES = {
  block = "# 🎀 ACP Block Metadata 🎀",
  tool = "# 🧰✨ ACP Tool Metadata ✨🧰",
  compacted = "# 🎉📦 ACP Compacted Transcript 📦🎉",
}

local FANCY_POPUP_SECTION_HEADINGS = {
  Summary = "Summary 💖✨",
  Content = "Content 🍭🌈",
  ["Raw output"] = "Raw output 🔥📦",
  Transcript = "Transcript 🌈📜",
  ["Expanded transcript"] = "Expanded transcript 🎉📜",
}

local function jump_window_to_row(win, row)
  pcall(function()
    vim.api.nvim_win_set_cursor(win, { row, 0 })
    pcall(vim.cmd, "normal! zz")
  end)
end

local function section_heading_for_line(line)
  if type(line) ~= "string" then
    return nil
  end
  line = line:gsub("^%s+", "")
  if not line:match("^[─━]+%s+") and not line:match("^[╭┌][─━]+%s+") then
    return nil
  end
  for _, heading in ipairs(SECTION_HEADINGS) do
    if (heading == "Assistant" and line_has_assistant_heading(line)) or line_has_heading(line, heading) then
      return heading
    end
  end
  return nil
end

local function collect_transcript_sections(lines)
  lines = type(lines) == "table" and lines or {}
  local sections = {}
  local start_idx = lines[1] == TRANSCRIPT_TRUNCATED_MARKER and 2 or 1

  for row = start_idx, #lines do
    local heading = section_heading_for_line(lines[row])
    if heading then
      sections[#sections + 1] = {
        heading = heading,
        start_row = row,
      }
    end
  end

  for idx, section in ipairs(sections) do
    local stop = idx < #sections and (sections[idx + 1].start_row - 1) or #lines
    while stop > section.start_row and lines[stop] == "" do
      stop = stop - 1
    end
    section.end_row = math.max(section.start_row, stop)
  end

  return sections
end

local function balance_unclosed_markdown_fences(lines)
  lines = type(lines) == "table" and lines or {}
  local balanced = nil
  local inside_fence = false

  for idx, line in ipairs(lines) do
    if section_heading_for_line(line) and inside_fence then
      if not balanced then
        balanced = {}
        for copy_idx = 1, idx - 1 do
          balanced[copy_idx] = lines[copy_idx]
        end
      end
      -- Bound malformed Markdown to the ACP section that produced it.
      balanced[#balanced + 1] = SYNTHETIC_MARKDOWN_FENCE_CLOSE
      inside_fence = false
    end

    if balanced then
      balanced[#balanced + 1] = line
    end
    if is_markdown_fence(line) then
      inside_fence = not inside_fence
    end
  end

  return balanced or lines
end

local function trailing_section_has_open_markdown_fence(lines)
  lines = type(lines) == "table" and lines or {}
  local inside_fence = false
  for _, line in ipairs(lines) do
    if section_heading_for_line(line) then
      inside_fence = false
    end
    if is_markdown_fence(line) then
      inside_fence = not inside_fence
    end
  end
  return inside_fence
end

local function append_crosses_unclosed_markdown_fence(lines, text)
  local inside_fence = trailing_section_has_open_markdown_fence(lines)
  for _, line in ipairs(vim.split(tostring(text or ""), "\n", { plain = true })) do
    if section_heading_for_line(line) then
      if inside_fence then
        return true
      end
      inside_fence = false
    end
    if is_markdown_fence(line) then
      inside_fence = not inside_fence
    end
  end
  return false
end

M.line_has_heading = line_has_heading
M.replace_heading_token = replace_heading_token
M.line_has_assistant_heading = line_has_assistant_heading
M.section_style_for_line = section_style_for_line
M.line_has_tail = line_has_tail
M.is_markdown_fence = is_markdown_fence
M.code_block_target_row = code_block_target_row
M.SECTION_HEADINGS = SECTION_HEADINGS
M.FANCY_SECTION_LABELS = FANCY_SECTION_LABELS
M.FANCY_POPUP_MARKDOWN_TITLES = FANCY_POPUP_MARKDOWN_TITLES
M.FANCY_POPUP_SECTION_HEADINGS = FANCY_POPUP_SECTION_HEADINGS
M.jump_window_to_row = jump_window_to_row
M.section_heading_for_line = section_heading_for_line
M.collect_transcript_sections = collect_transcript_sections
M.balance_unclosed_markdown_fences = balance_unclosed_markdown_fences
M.trailing_section_has_open_markdown_fence = trailing_section_has_open_markdown_fence
M.append_crosses_unclosed_markdown_fence = append_crosses_unclosed_markdown_fence

return M
