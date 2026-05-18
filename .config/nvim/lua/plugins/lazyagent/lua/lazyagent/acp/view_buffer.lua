local M = {}

local agent_logic = require("lazyagent.logic.agent")
local state = require("lazyagent.logic.state")
local view_diff = require("lazyagent.acp.view_diff")
local view_footer = require("lazyagent.acp.view_footer")
local pane_config = {}
local pane_buffers = {}
local next_pane_seq = 0
local transcript_ns = vim.api.nvim_create_namespace("lazyagent_acp_transcript")
local footer_ns = vim.api.nvim_create_namespace("lazyagent_acp_footer")
local diff_ns = vim.api.nvim_create_namespace("lazyagent_acp_diff")
local highlights_defined = false
local layout_autocmds_initialized = false
local metadata_popup_win = nil
local metadata_popup_source_buf = nil
local TRANSCRIPT_TRUNCATED_MARKER = "... earlier transcript omitted from buffer ..."
local FOLLOW_SCROLL_OFF = 0
local DEFAULT_SCROLL_OFF = 2
local ACP_TRANSCRIPT_FILETYPE = "lazyagent_acp"
local ACP_PIN_ICON = "󰐃"
local APPEND_BATCH_MS = 60
local DECORATE_PREFETCH_MARGIN = 80
local DECORATE_SYNC_LINE_LIMIT = 600
local DECORATE_CHUNK_SIZE = 400
local first_visible_window
local replace_buffer_lines
local set_buffer_lines
local scroll_buffer_to_end
local transcript_max_lines
local transcript_line_count
local refresh_buffer_layout
local refresh_buffer_from_path
local layout_entry
local buffer_is_visible
local set_window_size
local diff_view
local footer_view
local normalize_header_lines
local pinned_section_rows
local transcript_source_lines
local pane_id_for_bufnr
local agent_name_for_bufnr
local read_transcript_lines
local fancy_mode_enabled
local custom_background_groups = {}
local layout_state = {}
local suppress_transcript_window_refresh = false
local dedicated_transcript_windows = {}
local redirecting_transcript_windows = {}
local ACP_WINDOW_OPTIONS = {
  "number",
  "relativenumber",
  "cursorline",
  "wrap",
  "linebreak",
  "breakindent",
  "signcolumn",
  "statuscolumn",
  "foldcolumn",
  "foldenable",
  "foldmethod",
  "foldexpr",
  "winfixwidth",
  "winfixheight",
  "scrolloff",
  "smoothscroll",
  "statusline",
  "eventignorewin",
  "fillchars",
  "winhighlight",
}

local function close_timer(timer)
  if not timer then
    return
  end
  pcall(function() timer:stop() end)
  pcall(function() timer:close() end)
end

local function strdisplaywidth(text)
  local ok, width = pcall(vim.fn.strdisplaywidth, text)
  return ok and width or #tostring(text or "")
end

local function remove_list_value(list, value)
  if type(list) ~= "table" then
    return
  end
  for idx = #list, 1, -1 do
    if list[idx] == value then
      table.remove(list, idx)
    end
  end
end

local function cleanup_render_markdown_decorator(decorator, ns, bufnr)
  if type(decorator) ~= "table" then
    return
  end

  local marks = type(decorator.get) == "function" and decorator:get() or decorator.marks
  if vim.api.nvim_buf_is_valid(bufnr) and type(marks) == "table" then
    for _, mark in ipairs(marks) do
      if type(mark) == "table" and type(mark.hide) == "function" then
        pcall(mark.hide, mark, ns, bufnr)
      end
    end
  end

  decorator.marks = {}
  decorator.tick = nil
  decorator.running = false

  local timer = decorator.timer
  if timer then
    pcall(function() timer:stop() end)
    pcall(function() timer:close() end)
    decorator.timer = nil
  end
end

local function prune_invalid_render_markdown_state(manager, render_state, ui)
  if type(manager) == "table" and type(manager.buffers) == "table" then
    for idx = #manager.buffers, 1, -1 do
      local tracked = manager.buffers[idx]
      if not tracked or not vim.api.nvim_buf_is_valid(tracked) then
        table.remove(manager.buffers, idx)
      end
    end
  end

  if type(render_state) == "table" and type(render_state.cache) == "table" then
    for tracked, _ in pairs(render_state.cache) do
      if not tracked or not vim.api.nvim_buf_is_valid(tracked) then
        render_state.cache[tracked] = nil
      end
    end
  end

  if type(ui) == "table" and type(ui.cache) == "table" then
    for tracked, _ in pairs(ui.cache) do
      if not tracked or not vim.api.nvim_buf_is_valid(tracked) then
        cleanup_render_markdown_decorator(ui.cache[tracked], ui.ns, tracked)
        ui.cache[tracked] = nil
      end
    end
  end
end

local function cleanup_markdown_rendering(bufnr)
  if not bufnr then
    return
  end

  local is_valid = vim.api.nvim_buf_is_valid(bufnr)
  if is_valid then
    pcall(vim.treesitter.stop, bufnr)
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, transcript_ns, 0, -1)
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, footer_ns, 0, -1)
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, diff_ns, 0, -1)
  end

  local ok_manager, manager = pcall(require, "render-markdown.core.manager")
  if ok_manager and type(manager) == "table" then
    remove_list_value(manager.buffers, bufnr)
  end

  local ok_state, render_state = pcall(require, "render-markdown.state")
  if ok_state and type(render_state) == "table" and type(render_state.cache) == "table" then
    render_state.cache[bufnr] = nil
  end

  local ok_ui, ui = pcall(require, "render-markdown.core.ui")
  if ok_ui and type(ui) == "table" then
    if is_valid and ui.ns then
      pcall(vim.api.nvim_buf_clear_namespace, bufnr, ui.ns, 0, -1)
    end
    if type(ui.cache) == "table" then
      cleanup_render_markdown_decorator(ui.cache[bufnr], ui.ns, bufnr)
      ui.cache[bufnr] = nil
    end
  end

  prune_invalid_render_markdown_state(
    ok_manager and manager or nil,
    ok_state and render_state or nil,
    ok_ui and ui or nil
  )
end

local function is_metadata_popup_buffer(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  local ok, value = pcall(vim.api.nvim_buf_get_var, bufnr, "lazyagent_acp_metadata_popup")
  return ok and value == true
end

local function ensure_highlights()
  if highlights_defined then
    return
  end
  highlights_defined = true

  local defs = {
    FugitiveExtAdd = { default = true, bg = "#23384C" },
    FugitiveExtDelete = { default = true, bg = "#321e1e" },
    FugitiveExtAddText = { default = true, bg = "#005f5f" },
    FugitiveExtDeleteText = { default = true, bg = "#8c3b40" },
    LazyAgentACPUserHeader = { default = true, fg = "#e0af68", bold = true },
    LazyAgentACPAssistantHeader = { default = true, fg = "#9ece6a", bold = true },
    LazyAgentACPThinkingHeader = { default = true, fg = "#bb9af7", bold = true },
    LazyAgentACPSystemHeader = { default = true, fg = "#7dcfff", bold = true },
    LazyAgentACPErrorHeader = { default = true, fg = "#f7768e", bold = true },
    LazyAgentACPPlanHeader = { default = true, fg = "#e0af68", bold = true },
    LazyAgentACPToolHeader = { default = true, fg = "#7aa2f7", bold = true },
    LazyAgentACPTerminalHeader = { default = true, fg = "#73daca", bold = true },
    LazyAgentACPPinIcon = { default = true, fg = "#f7768e", bold = true },
    LazyAgentACPBorder = { default = true, link = "FloatBorder" },
    LazyAgentACPFooterActive = { default = true, link = "DiagnosticInfo" },
    LazyAgentACPFooterWaiting = { default = true, link = "DiagnosticWarn" },
    LazyAgentACPFooterError = { default = true, link = "DiagnosticError" },
    LazyAgentACPFooterMuted = { default = true, link = "Comment" },
    LazyAgentACPFooterMeta = { default = true, link = "SpecialComment" },
    LazyAgentACPCardTitle = { default = true, link = "Title" },
    LazyAgentACPCardField = { default = true, link = "Identifier" },
    LazyAgentACPDiffDelete = { default = true, link = "FugitiveExtDelete" },
    LazyAgentACPDiffAdd = { default = true, link = "FugitiveExtAdd" },
    LazyAgentACPDiffDeleteWord = { default = true, link = "FugitiveExtDeleteText" },
    LazyAgentACPDiffAddWord = { default = true, link = "FugitiveExtAddText" },
  }

  for name, spec in pairs(defs) do
    pcall(vim.api.nvim_set_hl, 0, name, spec)
  end
end

local function refresh_markdown_rendering(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local ft = vim.bo[bufnr].filetype
  if ft ~= ACP_TRANSCRIPT_FILETYPE and ft ~= "lazyagent" then
    return
  end

  local wins = vim.fn.win_findbuf(bufnr)
  if #wins == 0 or (transcript_line_count and transcript_line_count(bufnr) == 0) then
    cleanup_markdown_rendering(bufnr)
    return
  end

  pcall(vim.treesitter.start, bufnr, "markdown")

  local ok_manager, manager = pcall(require, "render-markdown.core.manager")
  if ok_manager and type(manager.attach) == "function" then
    pcall(manager.attach, bufnr)
  end

  local ok_render, render = pcall(require, "render-markdown")
  if ok_render and type(render.render) == "function" then
    pcall(render.render, {
      buf = bufnr,
      win = wins,
      event = "LazyAgentACPUpdate",
    })
  end
end

local function session_for_agent(agent_name)
  return agent_name and state.sessions and state.sessions[agent_name] or nil
end

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

local function backend_for_agent(agent_name)
  local session = session_for_agent(agent_name)
  local backend_name = session and session.backend or nil
  if not backend_name or backend_name == "" then
    return nil
  end
  return state.backends and state.backends[backend_name] or nil
end

local function runtime_conversation_timeline(bufnr)
  local agent_name = agent_name_for_bufnr(bufnr)
  local session = session_for_agent(agent_name)
  if session and type(session.acp_conversation_timeline) == "table" then
    return session.acp_conversation_timeline
  end
  local backend = backend_for_agent(agent_name)
  if backend and type(backend.get_conversation_timeline) == "function" then
    return backend.get_conversation_timeline(pane_id_for_bufnr(bufnr))
  end
  return {}
end

local function runtime_tool_timeline(bufnr)
  local agent_name = agent_name_for_bufnr(bufnr)
  local session = session_for_agent(agent_name)
  if session and type(session.acp_tool_timeline) == "table" then
    return session.acp_tool_timeline
  end
  return {}
end

local function visible_conversation_context(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local stop = transcript_line_count(bufnr)
  local lines = transcript_source_lines(bufnr, 0, stop)
  local sections = collect_transcript_sections(lines)
  if #sections == 0 then
    return {
      lines = lines,
      sections = sections,
      items = {},
      index = nil,
      section = nil,
      item = nil,
    }
  end

  local entry = layout_entry(bufnr)
  local items = type(entry.transcript_section_items) == "table" and entry.transcript_section_items or nil
  if type(items) ~= "table" or #items ~= #sections then
    items = {}
    local timeline = runtime_conversation_timeline(bufnr)
    local offset = math.max(#timeline - #sections, 0)
    for idx = 1, #sections do
      items[idx] = timeline[offset + idx]
    end
  end

  local row = vim.api.nvim_win_get_cursor(vim.api.nvim_get_current_win())[1]
  local index = #sections
  for idx, section in ipairs(sections) do
    if row < section.start_row then
      index = math.max(1, idx - 1)
      break
    end
    if row >= section.start_row and row <= section.end_row then
      index = idx
      break
    end
  end

  return {
    lines = lines,
    sections = sections,
    items = items,
    index = index,
    section = sections[index],
    item = items[index],
  }
end

local function current_display_conversation_context(bufnr, win)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  if not win or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= bufnr then
    return nil
  end

  local stop = transcript_line_count(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, stop, false)
  local sections = collect_transcript_sections(lines)
  if #sections == 0 then
    return nil
  end

  local entry = layout_entry(bufnr)
  local items = type(entry.transcript_section_items) == "table" and entry.transcript_section_items or nil
  if type(items) ~= "table" or #items ~= #sections then
    items = {}
    local timeline = runtime_conversation_timeline(bufnr)
    local offset = math.max(#timeline - #sections, 0)
    for idx = 1, #sections do
      items[idx] = timeline[offset + idx]
    end
  end

  local row = vim.api.nvim_win_get_cursor(win)[1]
  local index = nil
  for idx, section in ipairs(sections) do
    if row >= section.start_row and row <= section.end_row then
      index = idx
      break
    end
    if row < section.start_row then
      index = math.max(1, idx - 1)
      break
    end
  end
  index = index or #sections

  return {
    lines = lines,
    sections = sections,
    items = items,
    index = index,
    section = sections[index],
    item = items[index],
  }
end

local function section_text(lines, section)
  if type(lines) ~= "table" or type(section) ~= "table" then
    return ""
  end
  local chunk = {}
  for row = section.start_row, section.end_row do
    chunk[#chunk + 1] = lines[row] or ""
  end
  while #chunk > 0 and chunk[#chunk] == "" do
    table.remove(chunk)
  end
  return table.concat(chunk, "\n")
end

local function section_body_text(lines, section)
  if type(lines) ~= "table" or type(section) ~= "table" then
    return ""
  end
  local chunk = {}
  for row = (section.start_row or 0) + 1, section.end_row or 0 do
    local text = tostring(lines[row] or "")
    if text:sub(1, 1) == " " then
      text = text:sub(2)
    end
    chunk[#chunk + 1] = text
  end
  while #chunk > 0 and chunk[#chunk] == "" do
    table.remove(chunk)
  end
  return table.concat(chunk, "\n")
end

local function normalize_popup_text(text)
  local lines = vim.split(tostring(text or ""), "\n", { plain = true })
  for idx, line in ipairs(lines) do
    if line:sub(1, 1) == " " then
      lines[idx] = line:sub(2)
    end
  end
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end
  return table.concat(lines, "\n")
end

local function text_looks_like_transcript(text)
  text = tostring(text or "")
  if text == "" then
    return false
  end

  local heading_count = 0
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    if line == TRANSCRIPT_TRUNCATED_MARKER or section_heading_for_line(line) then
      heading_count = heading_count + 1
      if heading_count >= 2 then
        return true
      end
    end
  end

  return false
end

local function copy_to_clipboard(text, label)
  text = tostring(text or "")
  if text == "" then
    vim.notify("Nothing to copy", vim.log.levels.INFO)
    return
  end
  vim.fn.setreg('"', text)
  pcall(vim.fn.setreg, "+", text)
  vim.notify((label or "Copied") .. " to clipboard", vim.log.levels.INFO)
end

local function tool_entry_for_item(bufnr, item)
  if type(item) ~= "table" or not item.toolCallId or item.toolCallId == "" then
    return nil
  end

  for _, entry in ipairs(runtime_tool_timeline(bufnr)) do
    if type(entry) == "table" and entry.toolCallId == item.toolCallId then
      return entry
    end
  end

  local backend = backend_for_agent(agent_name_for_bufnr(bufnr))
  if backend and type(backend.get_tool_timeline_entry) == "function" then
    return backend.get_tool_timeline_entry(pane_id_for_bufnr(bufnr), item.toolCallId)
  end

  return nil
end

local function show_outline_picker(bufnr, pinned_only)
  local context = visible_conversation_context(bufnr)
  local win = vim.api.nvim_get_current_win()
  local entries = {}

  for idx, section in ipairs(context and context.sections or {}) do
    local item = context.items[idx]
    if not pinned_only or (item and item.pinned == true) then
      entries[#entries + 1] = {
        section = section,
        item = item,
      }
    end
  end

  if #entries == 0 then
    vim.notify(pinned_only and "No pinned blocks" or "No transcript blocks", vim.log.levels.INFO)
    return
  end

  vim.ui.select(entries, {
    prompt = pinned_only and "Pinned ACP blocks:" or "ACP outline:",
    format_item = function(entry)
      local item = entry.item or {}
      local pin = item.pinned and "[pin] " or ""
      local label = item.title or item.heading or entry.section.heading or "Block"
      local summary = item.summary and item.summary ~= "" and (" - " .. item.summary) or ""
      local status = item.status and item.status ~= "" and (" [" .. item.status .. "]") or ""
      return string.format("%s%s%s%s", pin, label, status, summary)
    end,
  }, function(choice)
    if choice and vim.api.nvim_win_is_valid(win) then
      jump_window_to_row(win, choice.section.start_row)
    end
  end)
end

local function toggle_current_pin(bufnr)
  local context = visible_conversation_context(bufnr)
  local item = context and context.item or nil
  if not item or not item.id or item.id == "" then
    vim.notify("No pinnable ACP block under cursor", vim.log.levels.INFO)
    return
  end

  local backend = backend_for_agent(agent_name_for_bufnr(bufnr))
  local pinned = nil
  if backend and type(backend.toggle_conversation_pin) == "function" then
    pinned = backend.toggle_conversation_pin(pane_id_for_bufnr(bufnr), item.id)
  end
  if pinned == nil then
    pinned = not item.pinned
    item.pinned = pinned
  end

  vim.notify(pinned and "Pinned current block" or "Unpinned current block", vim.log.levels.INFO)
  local session = session_for_agent(agent_name_for_bufnr(bufnr))
  local transcript_path = session and session.transcript_path or nil
  if not transcript_path or transcript_path == "" then
    local ok, value = pcall(vim.api.nvim_buf_get_var, bufnr, "lazyagent_acp_transcript_path")
    transcript_path = ok and value or nil
  end
  pcall(
    refresh_buffer_from_path,
    bufnr,
    transcript_path,
    { force = true }
  )
end

local function copy_current_block(bufnr)
  local context = visible_conversation_context(bufnr)
  local text = section_text(context and context.lines or {}, context and context.section or nil)
  copy_to_clipboard(text, "Copied current block")
end

local function copy_current_tool_output(bufnr)
  local context = visible_conversation_context(bufnr)
  local entry = tool_entry_for_item(bufnr, context and context.item or nil)
  if not entry then
    vim.notify("No tool output for this block", vim.log.levels.INFO)
    return
  end

  local parts = {}
  if entry.rendered_content and entry.rendered_content ~= "" then
    parts[#parts + 1] = entry.rendered_content
  end
  if entry.rendered_raw_output and entry.rendered_raw_output ~= "" then
    if #parts > 0 then
      parts[#parts + 1] = ""
    end
    parts[#parts + 1] = "Raw output:"
    parts[#parts + 1] = entry.rendered_raw_output
  end

  if #parts == 0 then
    local message = entry.compacted == true
        and "Tool output was compacted; open the full/raw ACP transcript for details"
      or "No tool output for this block"
    vim.notify(message, vim.log.levels.INFO)
    return
  end

  copy_to_clipboard(table.concat(parts, "\n"), "Copied tool output")
end

  local function open_current_tool_output(bufnr)
    local context = visible_conversation_context(bufnr)
    local item = context and context.item or nil
    if not item or not item.toolCallId or item.toolCallId == "" then
      vim.notify("No tool output for this block", vim.log.levels.INFO)
      return
    end

    local backend = backend_for_agent(agent_name_for_bufnr(bufnr))
    if backend and type(backend.show_tool_timeline_entry) == "function" then
      if backend.show_tool_timeline_entry(pane_id_for_bufnr(bufnr), item.toolCallId) then
        return
      end
    end

    vim.notify("Tool output viewer is unavailable for this block", vim.log.levels.WARN)
  end

  local function close_metadata_popup()
    local popup_buf = nil
    if metadata_popup_win and vim.api.nvim_win_is_valid(metadata_popup_win) then
      popup_buf = vim.api.nvim_win_get_buf(metadata_popup_win)
    end
    if popup_buf and vim.api.nvim_buf_is_valid(popup_buf) then
      cleanup_markdown_rendering(popup_buf)
    end
    if metadata_popup_win and vim.api.nvim_win_is_valid(metadata_popup_win) then
      pcall(vim.api.nvim_win_close, metadata_popup_win, true)
    end
    metadata_popup_win = nil
    metadata_popup_source_buf = nil
  end

  local function metadata_popup_is_open()
    return metadata_popup_win ~= nil and vim.api.nvim_win_is_valid(metadata_popup_win)
  end

  local function install_source_popup_close_keymap(bufnr)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    vim.keymap.set("n", "q", function()
      if metadata_popup_is_open() and metadata_popup_source_buf == bufnr then
        close_metadata_popup()
        return "<Ignore>"
      end
      return "q"
    end, {
      buffer = bufnr,
      expr = true,
      noremap = true,
      nowait = true,
      silent = true,
      replace_keycodes = true,
      desc = "LazyAgentACP: close metadata popup",
    })
  end

  local function normalize_popup_lines(lines)
    local normalized = {}
    for _, line in ipairs(lines or {}) do
      local text = tostring(line or "")
      local split = vim.split(text, "\n", { plain = true })
      if #split == 0 then
        normalized[#normalized + 1] = ""
      else
        vim.list_extend(normalized, split)
      end
    end
    if #normalized == 0 then
      normalized[1] = "(no metadata)"
    end
    return normalized
  end

  local function append_scalar_field(lines, label, value)
    if value == nil then
      return
    end
    local text = tostring(value)
    if text == "" then
      return
    end
    lines[#lines + 1] = string.format("%s: %s", label, text)
  end

  local function append_list_field(lines, label, values)
    if type(values) ~= "table" or vim.tbl_isempty(values) then
      return
    end
    lines[#lines + 1] = label .. ":"
    for _, value in ipairs(values) do
      local text = tostring(value or "")
      if text ~= "" then
        lines[#lines + 1] = "- " .. text
      end
    end
  end

  local function append_text_section(lines, heading, text)
    text = tostring(text or "")
    if text == "" then
      return
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = heading .. ":"
    vim.list_extend(lines, vim.split(text, "\n", { plain = true }))
  end

  local function popup_markdown_title(bufnr, kind, fallback)
    if fancy_mode_enabled(bufnr) then
      return FANCY_POPUP_MARKDOWN_TITLES[kind] or fallback
    end
    return fallback
  end

  local function popup_window_title(bufnr, title, emoji)
    if not fancy_mode_enabled(bufnr) then
      return title
    end
    return string.format("%s %s %s", emoji, title, emoji)
  end

  local function popup_section_heading(bufnr, heading)
    if fancy_mode_enabled(bufnr) then
      return FANCY_POPUP_SECTION_HEADINGS[heading] or heading
    end
    return heading
  end

  local function compacted_transcript_preview_lines(bufnr, item)
    if type(item) ~= "table" or item.kind ~= "compacted" then
      return {}
    end

    local start_row = tonumber(item.compacted_relative_start_row)
    local stop_row = tonumber(item.compacted_relative_stop_row)
    if not start_row or not stop_row then
      return {}
    end

    local ok, transcript_path = pcall(vim.api.nvim_buf_get_var, bufnr, "lazyagent_acp_transcript_path")
    if not ok or type(transcript_path) ~= "string" or transcript_path == "" then
      return {}
    end

    local slice_lines = read_transcript_lines(transcript_path, item.compacted_max_lines)
    if type(slice_lines) ~= "table" or #slice_lines == 0 then
      return {}
    end

    start_row = math.max(1, math.floor(start_row))
    stop_row = math.max(start_row, math.floor(stop_row))
    if start_row > #slice_lines then
      return {}
    end
    stop_row = math.min(stop_row, #slice_lines)

    local preview = vim.list_slice(slice_lines, start_row, stop_row)
    while #preview > 0 and preview[#preview] == "" do
      table.remove(preview)
    end
    return preview
  end

  local function popup_source_window(bufnr)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return nil
    end

    local source_win = vim.api.nvim_get_current_win()
    if not source_win or not vim.api.nvim_win_is_valid(source_win) then
      return nil
    end
    if vim.api.nvim_win_get_buf(source_win) ~= bufnr then
      return nil
    end
    local ok_cfg, cfg = pcall(vim.api.nvim_win_get_config, source_win)
    if not ok_cfg or not cfg or cfg.relative ~= "" then
      return nil
    end
    local tracked = dedicated_transcript_windows[tostring(source_win)]
    if not tracked or tracked.bufnr ~= bufnr then
      return nil
    end

    local ok, is_transcript = pcall(function()
      return vim.b[bufnr].lazyagent_acp_transcript
    end)
    if not ok or is_transcript ~= true then
      return nil
    end
    if vim.bo[bufnr].filetype ~= ACP_TRANSCRIPT_FILETYPE then
      return nil
    end

    return source_win
  end

  local function build_block_metadata_lines(bufnr, context, item)
    local section = context and context.section or {}
    local body = section_body_text(context and context.lines or {}, section)
    local item_body = type(item) == "table" and tostring(item.body or "") or ""
    if body == "" and item_body ~= "" and not text_looks_like_transcript(item_body) then
      body = item_body
    end

    local metadata = {
      id = item and item.id or nil,
      seq = item and item.seq or nil,
      kind = item and item.kind or nil,
      heading = item and item.heading or section.heading,
      title = item and item.title or section.heading,
      status = item and item.status or nil,
      path = item and item.path or nil,
      toolCallId = item and item.toolCallId or nil,
      pinned = item and item.pinned == true or false,
      summary = item and item.summary or nil,
      transcript_range = section.start_row and string.format("%d-%d", section.start_row, section.end_row or section.start_row) or nil,
    }

    local lines = { popup_markdown_title(bufnr, "block", "# ACP Block Metadata"), "" }
    append_scalar_field(lines, "ID", metadata.id)
    append_scalar_field(lines, "Seq", metadata.seq)
    append_scalar_field(lines, "Title", metadata.title)
    append_scalar_field(lines, "Heading", metadata.heading)
    append_scalar_field(lines, "Kind", metadata.kind)
    append_scalar_field(lines, "Status", metadata.status)
    append_scalar_field(lines, "Path", metadata.path)
    append_scalar_field(lines, "Tool Call", metadata.toolCallId)
    append_scalar_field(lines, "Pinned", metadata.pinned)
    append_scalar_field(lines, "Transcript lines", metadata.transcript_range)
    append_text_section(lines, popup_section_heading(bufnr, "Summary"), metadata.summary)
    append_text_section(lines, popup_section_heading(bufnr, "Content"), body)
    return lines
  end

  local function preferred_tool_popup_sections(context, item, entry)
    local section = context and context.section or {}
    local transcript_body = section_body_text(context and context.lines or {}, section)
    local item_body = type(item) == "table" and tostring(item.body or "") or ""
    local content = tostring(entry and entry.rendered_content or "")
    local raw_output = tostring(entry and entry.rendered_raw_output or "")

    if text_looks_like_transcript(content) then
      content = ""
    end
    if text_looks_like_transcript(raw_output) then
      raw_output = ""
    end
    if content == "" and item_body ~= "" and not text_looks_like_transcript(item_body) then
      content = item_body
    end
    if content == "" then
      content = transcript_body
    end

    if normalize_popup_text(raw_output) == normalize_popup_text(content) then
      raw_output = ""
    end
    if normalize_popup_text(transcript_body) == normalize_popup_text(content) then
      transcript_body = ""
    end

    return content, raw_output, transcript_body
  end

  local function build_tool_metadata_lines(bufnr, context, item, entry)
    local section = context and context.section or {}
    local paths = type(entry and entry.paths) == "table" and vim.deepcopy(entry.paths) or {}
    if #paths == 0 and item and item.path and item.path ~= "" then
      paths = { item.path }
    end
    local content, raw_output, transcript_body = preferred_tool_popup_sections(context, item, entry)
    local metadata = {
      toolCallId = entry and entry.toolCallId or item and item.toolCallId or nil,
      title = entry and entry.title or item and item.title or nil,
      heading = entry and entry.heading or item and item.heading or section.heading,
      status = entry and entry.status or item and item.status or nil,
      kind = entry and entry.kind or item and item.kind or "tool",
      pinned = (entry and entry.pinned == true) or (item and item.pinned == true) or false,
      summary = entry and entry.summary or item and item.summary or nil,
      paths = paths,
      transcript_range = section.start_row and string.format("%d-%d", section.start_row, section.end_row or section.start_row) or nil,
      conversation_item_id = item and item.id or nil,
    }

    local lines = { popup_markdown_title(bufnr, "tool", "# ACP Tool Metadata"), "" }
    append_scalar_field(lines, "Tool Call", metadata.toolCallId)
    append_scalar_field(lines, "Title", metadata.title)
    append_scalar_field(lines, "Heading", metadata.heading)
    append_scalar_field(lines, "Kind", metadata.kind)
    append_scalar_field(lines, "Status", metadata.status)
    append_scalar_field(lines, "Pinned", metadata.pinned)
    append_scalar_field(lines, "Transcript lines", metadata.transcript_range)
    append_scalar_field(lines, "Conversation item", metadata.conversation_item_id)
    append_list_field(lines, "Paths", metadata.paths)
    append_text_section(lines, popup_section_heading(bufnr, "Summary"), metadata.summary)
    append_text_section(lines, popup_section_heading(bufnr, "Content"), content)
    append_text_section(lines, popup_section_heading(bufnr, "Raw output"), raw_output)
    append_text_section(lines, popup_section_heading(bufnr, "Transcript"), transcript_body)
    return lines
  end

  local function build_compacted_metadata_lines(bufnr, context, item)
    local section = context and context.section or {}
    local preview_lines = compacted_transcript_preview_lines(bufnr, item)
    local lines = { popup_markdown_title(bufnr, "compacted", "# ACP Compacted Transcript"), "" }
    append_scalar_field(lines, "Title", item and item.title or nil)
    append_scalar_field(lines, "Compacted sections", item and item.compacted_section_count or nil)
    append_scalar_field(
      lines,
      "Displayed lines",
      section.start_row and string.format("%d-%d", section.start_row, section.end_row or section.start_row) or nil
    )
    append_text_section(lines, popup_section_heading(bufnr, "Summary"), item and item.summary or nil)
    append_text_section(
      lines,
      popup_section_heading(bufnr, "Expanded transcript"),
      table.concat(preview_lines, "\n")
    )
    if #preview_lines == 0 then
      append_text_section(
        lines,
        popup_section_heading(bufnr, "Expanded transcript"),
        "(source transcript unavailable)"
      )
    end
    return lines
  end

  local function metadata_popup_spec(bufnr, win)
    local context = current_display_conversation_context(bufnr, win)
    if not context or not context.section then
      return nil
    end

    local entry = layout_entry(bufnr)
    local indexed_item = type(entry.transcript_section_items) == "table" and entry.transcript_section_items[context.index] or nil
    local item = indexed_item or context.item or {}
    if item.kind == "compacted" then
      local title = popup_window_title(bufnr, tostring(item.title or "Compacted transcript"), "🎉📦")
      return {
        title = " " .. title .. " ",
        lines = build_compacted_metadata_lines(bufnr, context, item),
      }
    end

    local tool_entry = tool_entry_for_item(bufnr, item)
    local section_heading = context.section and context.section.heading or nil
    local is_tool_section = section_heading == "Tool" or section_heading == "Edited"
    if tool_entry or is_tool_section or item.kind == "tool" or (item.toolCallId and item.toolCallId ~= "") then
      local title = tool_entry and (tool_entry.title or tool_entry.toolCallId)
        or item.title
        or item.toolCallId
        or section_heading
        or "ACP Tool Metadata"
      title = popup_window_title(bufnr, tostring(title), "🧰✨")
      return {
        title = " " .. tostring(title) .. " ",
        lines = build_tool_metadata_lines(bufnr, context, item, tool_entry),
      }
    end

    local title = item.title or context.section.heading or "ACP Block Metadata"
    title = popup_window_title(bufnr, tostring(title), "🎀🌈")
    return {
      title = " " .. tostring(title) .. " ",
      lines = build_block_metadata_lines(bufnr, context, item),
    }
  end

  local function cursor_screen_position(win)
    local cursor = vim.api.nvim_win_get_cursor(win)
    local ok_pos, pos = pcall(vim.fn.screenpos, win, cursor[1], cursor[2] + 1)
    if ok_pos and type(pos) == "table" and tonumber(pos.row) and tonumber(pos.col) then
      local row = math.max(0, (tonumber(pos.row) or 1) - 1)
      local col = math.max(0, (tonumber(pos.endcol) or tonumber(pos.col) or 1) - 1)
      return row, col
    end

    local ok_win, win_pos = pcall(vim.api.nvim_win_get_position, win)
    if ok_win and type(win_pos) == "table" and win_pos[1] ~= nil and win_pos[2] ~= nil then
      return math.max(0, win_pos[1] + math.max(0, (vim.fn.winline() or 1) - 1)),
        math.max(0, win_pos[2] + math.max(0, (vim.fn.wincol() or 1) - 1))
    end

    return 0, 0
  end

  local function popup_geometry(win, lines)
    local ui = vim.api.nvim_list_uis()[1] or {}
    local editor_height = math.max(1, tonumber(ui.height) or vim.o.lines or 24)
    local editor_width = math.max(1, tonumber(ui.width) or vim.o.columns or 80)
    local max_width = math.max(1, editor_width - 2)
    local max_height = math.max(1, editor_height - 2)
    local width_limit = math.min(max_width, math.max(24, math.min(72, math.floor(editor_width * 0.42))))
    local height_limit = math.min(max_height, math.max(6, math.min(16, math.floor(editor_height * 0.45))))
    local max_line_width = 0
    for _, line in ipairs(lines) do
      max_line_width = math.max(max_line_width, strdisplaywidth(line))
    end

    local preferred_width = math.max(28, math.min(max_line_width + 2, 60))
    local preferred_height = math.max(6, math.min(#lines, 14))
    local width = math.max(1, math.min(width_limit, preferred_width))
    local height = math.max(1, math.min(height_limit, preferred_height))
    local cursor_row, cursor_col = cursor_screen_position(win)
    local right_space = math.max(0, editor_width - cursor_col - 2)
    local left_space = math.max(0, cursor_col - 1)

    local col = cursor_col + 2
    if right_space < width and left_space >= width then
      col = cursor_col - width - 1
    else
      col = math.min(col, math.max(0, editor_width - width))
    end
    col = math.max(0, math.min(col, math.max(0, editor_width - width)))

    local row
    if cursor_row >= height + 1 then
      row = cursor_row - height
    else
      row = cursor_row - math.min(2, height - 1)
    end
    row = math.max(0, math.min(row, math.max(0, editor_height - height)))

    return width, height, row, col
  end

  local function show_metadata_popup(bufnr)
    local source_win = popup_source_window(bufnr)
    if not source_win then
      return
    end

    local spec = metadata_popup_spec(bufnr, source_win)
    if not spec then
      vim.notify("No ACP block under cursor", vim.log.levels.INFO)
      return
    end

    close_metadata_popup()

    local lines = normalize_popup_lines(spec.lines)
    local width, height, row, col = popup_geometry(source_win, lines)
    local popup_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[popup_buf].bufhidden = "wipe"
    vim.bo[popup_buf].swapfile = false
    vim.bo[popup_buf].modifiable = true
    vim.bo[popup_buf].readonly = false
    vim.bo[popup_buf].filetype = "markdown"
    vim.b[popup_buf].lazyagent_acp_metadata_popup = true
    vim.api.nvim_buf_set_lines(popup_buf, 0, -1, false, lines)
    vim.bo[popup_buf].modifiable = false
    vim.bo[popup_buf].readonly = true

    metadata_popup_win = vim.api.nvim_open_win(popup_buf, true, {
      relative = "editor",
      row = row,
      col = col,
      width = width,
      height = height,
      style = "minimal",
      border = "rounded",
      title = spec.title,
      title_pos = "center",
      zindex = 90,
    })
    metadata_popup_source_buf = bufnr
    install_source_popup_close_keymap(bufnr)

    vim.wo[metadata_popup_win].wrap = true
    vim.wo[metadata_popup_win].linebreak = true
    vim.wo[metadata_popup_win].cursorline = false
    vim.wo[metadata_popup_win].number = false
    vim.wo[metadata_popup_win].relativenumber = false
    vim.wo[metadata_popup_win].signcolumn = "no"
    vim.wo[metadata_popup_win].foldcolumn = "0"
    vim.wo[metadata_popup_win].winhighlight = "FloatBorder:LazyAgentACPBorder"

    local function close_and_restore_focus()
      close_metadata_popup()
      if source_win and vim.api.nvim_win_is_valid(source_win) then
        pcall(vim.api.nvim_set_current_win, source_win)
      end
    end

    vim.keymap.set("n", "q", close_and_restore_focus, {
      buffer = popup_buf,
      noremap = true,
      nowait = true,
      silent = true,
      desc = "LazyAgentACP: close metadata popup",
    })
    vim.keymap.set("n", "<Esc>", close_and_restore_focus, {
      buffer = popup_buf,
      noremap = true,
      silent = true,
      desc = "LazyAgentACP: close metadata popup",
    })
  end

  local function preview_current_diff_source(bufnr)
    if not diff_view or type(diff_view.preview_diff_block_under_cursor) ~= "function" then
      vim.notify("Diff preview is unavailable", vim.log.levels.WARN)
      return
    end

    local ok, opened = pcall(diff_view.preview_diff_block_under_cursor, bufnr)
    if not ok then
      vim.notify("LazyAgentACP: failed to preview diff source", vim.log.levels.WARN)
      return
    end
    if not opened then
      vim.notify("No diff block under cursor", vim.log.levels.INFO)
    end
  end

  local function show_action_menu(bufnr)
    local context = visible_conversation_context(bufnr)
    if not context or not context.section then
      vim.notify("No ACP block under cursor", vim.log.levels.INFO)
      return
    end

    local item = context.item or {}
    local backend = backend_for_agent(agent_name_for_bufnr(bufnr))
    local actions = {
      {
        label = "Switch provider",
        action = function()
          require("lazyagent.logic.session").switch_acp_provider(agent_name_for_bufnr(bufnr))
        end,
      },
      {
        label = "Sessions",
        action = function()
          require("lazyagent.logic.session").pick_acp_sessions(agent_name_for_bufnr(bufnr))
        end,
      },
      {
        label = "Outline",
        action = function()
          show_outline_picker(bufnr, false)
        end,
      },
      {
        label = "Pinned",
        action = function()
          show_outline_picker(bufnr, true)
        end,
      },
      {
        label = item.pinned and "Unpin current block" or "Pin current block",
        action = function()
          toggle_current_pin(bufnr)
        end,
      },
      {
        label = "Copy current block",
        action = function()
          copy_current_block(bufnr)
        end,
      },
      {
        label = "Show metadata",
        action = function()
          show_metadata_popup(bufnr)
        end,
      },
    }

    if backend and type(backend.show_tool_timeline) == "function" then
      actions[#actions + 1] = {
        label = "Tool timeline",
        action = function()
          backend.show_tool_timeline(pane_id_for_bufnr(bufnr))
        end,
      }
    end

    if diff_view and type(diff_view.has_diff_block_under_cursor) == "function"
        and diff_view.has_diff_block_under_cursor(bufnr) then
      actions[#actions + 1] = {
        label = "Preview diff source",
        action = function()
          preview_current_diff_source(bufnr)
        end,
      }
    end

    if item.toolCallId and item.toolCallId ~= "" then
      actions[#actions + 1] = {
        label = "Open tool output",
        action = function()
          open_current_tool_output(bufnr)
        end,
      }
      actions[#actions + 1] = {
        label = "Copy tool output",
        action = function()
          copy_current_tool_output(bufnr)
        end,
      }
    end

    vim.ui.select(actions, {
      prompt = "ACP actions:",
      format_item = function(entry)
        return entry.label
      end,
    }, function(choice)
      if choice and type(choice.action) == "function" then
        choice.action()
      end
    end)
end

local function tail_prefix(line)
  return (line:gsub("[%s─]+$", ""))
end

local function fancy_header_line(line)
  local heading = section_heading_for_line(line)
  local replacement = heading and FANCY_SECTION_LABELS[heading] or nil
  if not replacement or line:find(replacement, 1, true) then
    return line
  end
  return replace_heading_token(line, heading, replacement)
end

local function header_target_width(bufnr)
  local win = first_visible_window(bufnr)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return nil
  end
  return math.max(0, vim.api.nvim_win_get_width(win))
end

local function overlay_target_width(bufnr)
  local win = first_visible_window(bufnr)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return 80
  end
  return math.max(12, vim.api.nvim_win_get_width(win) - 2)
end

local function line_diff_range(left, right)
  left = type(left) == "table" and left or {}
  right = type(right) == "table" and right or {}

  local max_len = math.max(#left, #right)
  local first_diff = nil
  for idx = 1, max_len do
    if left[idx] ~= right[idx] then
      first_diff = idx
      break
    end
  end
  if not first_diff then
    return nil, nil, nil
  end

  local left_tail = #left
  local right_tail = #right
  while left_tail >= first_diff and right_tail >= first_diff and left[left_tail] == right[right_tail] do
    left_tail = left_tail - 1
    right_tail = right_tail - 1
  end

  return first_diff, left_tail, right_tail
end

transcript_source_lines = function(bufnr, start_idx, end_idx)
  local raw = layout_entry(bufnr).transcript_source_lines
  if type(raw) ~= "table" then
    return vim.api.nvim_buf_get_lines(bufnr, start_idx, end_idx, false)
  end

  local start_row = math.max(0, tonumber(start_idx) or 0)
  local stop_row = end_idx == -1 and #raw or math.max(start_row, tonumber(end_idx) or #raw)
  stop_row = math.min(#raw, stop_row)

  local lines = {}
  for idx = start_row + 1, stop_row do
    lines[#lines + 1] = raw[idx]
  end
  return lines
end

local function normalize_transcript_display(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local transcript_stop = transcript_line_count(bufnr)
  if transcript_stop <= 0 then
    return nil
  end

  local normalized = transcript_source_lines(bufnr, 0, transcript_stop)
  normalized = select(1, normalize_header_lines(bufnr, normalized))
  if diff_view and type(diff_view.normalize_diff_display_lines) == "function" then
    normalized = select(1, diff_view.normalize_diff_display_lines(bufnr, normalized, header_target_width(bufnr)))
  end

  local current = vim.api.nvim_buf_get_lines(bufnr, 0, transcript_stop, false)
  local first_diff, current_last, normalized_last = line_diff_range(current, normalized)
  if not first_diff then
    return nil
  end

  replace_buffer_lines(
    bufnr,
    first_diff - 1,
    current_last,
    vim.list_slice(normalized, first_diff, normalized_last)
  )
  return first_diff - 1
end

local function cancel_deferred_decoration(bufnr)
  local entry = layout_entry(bufnr)
  entry.decoration_generation = (entry.decoration_generation or 0) + 1
  return entry.decoration_generation
end

local function visible_transcript_range(bufnr)
  local transcript_stop = transcript_line_count(bufnr)
  if transcript_stop <= 0 then
    return 0, 0
  end

  local win = first_visible_window(bufnr)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return 0, math.min(transcript_stop, DECORATE_CHUNK_SIZE)
  end

  local ok, bounds = pcall(vim.api.nvim_win_call, win, function()
    return { vim.fn.line("w0"), vim.fn.line("w$") }
  end)
  if not ok or type(bounds) ~= "table" then
    return 0, math.min(transcript_stop, DECORATE_CHUNK_SIZE)
  end

  local top = math.max(1, tonumber(bounds[1]) or 1)
  local bottom = math.max(top, tonumber(bounds[2]) or top)
  local range_start = math.max(0, top - 1 - DECORATE_PREFETCH_MARGIN)
  local range_stop = math.min(transcript_stop, bottom + DECORATE_PREFETCH_MARGIN)
  return range_start, math.max(range_start, range_stop)
end

normalize_header_lines = function(bufnr, lines)
  local width = header_target_width(bufnr)
  local fancy = fancy_mode_enabled(bufnr)
  if (not width or width <= 0) and not fancy then
    return lines, false
  end

  local changed = false
  local normalized = nil
  for idx, line in ipairs(lines) do
    local rebuilt = line
    if fancy and (rebuilt:match("^─ ") or rebuilt:match("^╭─ ")) then
      rebuilt = fancy_header_line(rebuilt)
    end
    if width and width > 0 and rebuilt:match("^─ ") and line_has_tail(rebuilt) then
      local prefix = tail_prefix(rebuilt)
      local prefix_width = strdisplaywidth(prefix)
      local tail_len = math.max(8, width - prefix_width - 1)
      rebuilt = prefix .. " " .. string.rep("─", tail_len)
    end
    if rebuilt ~= line then
      normalized = normalized or vim.deepcopy(lines)
      normalized[idx] = rebuilt
      changed = true
    end
  end

  return normalized or lines, changed
end

local function decorate_transcript_range(bufnr, start_idx, end_idx)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  ensure_highlights()
  local transcript_stop = transcript_line_count(bufnr)
  local range_start = math.max(0, tonumber(start_idx) or 0)
  local range_stop = math.max(range_start, math.min(transcript_stop, tonumber(end_idx) or transcript_stop))
  if range_start >= range_stop then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, range_start, range_stop, false)
  local normalized, changed = normalize_header_lines(bufnr, lines)
  if changed then
    replace_buffer_lines(bufnr, range_start, range_stop, normalized)
    lines = normalized
  end

  vim.api.nvim_buf_clear_namespace(bufnr, transcript_ns, range_start, range_stop)
  local display_meta = layout_entry(bufnr).transcript_display_meta or {}
  local heading_rows = type(display_meta.heading_rows) == "table" and display_meta.heading_rows or {}
  local pinned_rows = pinned_section_rows(bufnr, vim.api.nvim_buf_get_lines(bufnr, 0, transcript_stop, false))
  for idx, line in ipairs(lines) do
    local row = range_start + idx - 1
    local header_hl = nil
    if line:match("^─ ") or line:match("^╭─ ") then
      header_hl = section_style_for_line(line)
    else
      local card_heading = heading_rows[row + 1]
      if card_heading == "title" then
        header_hl = "LazyAgentACPCardTitle"
      elseif card_heading == "field" then
        header_hl = "LazyAgentACPCardField"
      end
    end
    if header_hl then
      -- Prefer using vim.highlight.range for a full-line highlight region. Fall back to
      -- extmark or nvim_buf_add_highlight if not available.
      local ok = pcall(function()
        local start_pos = { row, 0 }
        local end_pos = { row, #line }
        vim.highlight.range(bufnr, transcript_ns, header_hl, start_pos, end_pos)
      end)
      if not ok then
        local ok2 = pcall(function()
          vim.api.nvim_buf_set_extmark(bufnr, transcript_ns, row, 0, { hl_group = header_hl, hl_eol = true })
        end)
        if not ok2 then
          pcall(function() vim.api.nvim_buf_add_highlight(bufnr, transcript_ns, header_hl, row, 0, -1) end)
        end
      end
    end
    if pinned_rows[row + 1] then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, transcript_ns, row, 0, {
        virt_text = { { " " .. ACP_PIN_ICON, "LazyAgentACPPinIcon" } },
        virt_text_pos = "right_align",
        priority = 250,
      })
    end
  end
end

local function queue_deferred_transcript_decoration(bufnr, ranges, generation)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local entry = layout_entry(bufnr)
  local function step(range_idx, cursor)
    if not vim.api.nvim_buf_is_valid(bufnr) or entry.decoration_generation ~= generation then
      return
    end
    if not buffer_is_visible(bufnr) then
      entry.pending_full_refresh = true
      return
    end

    local range = ranges[range_idx]
    if not range then
      return
    end

    local start_idx = cursor or range[1]
    local next_stop = math.min(range[2], start_idx + DECORATE_CHUNK_SIZE)
    decorate_transcript_range(bufnr, start_idx, next_stop)
    if next_stop < range[2] then
      vim.schedule(function()
        step(range_idx, next_stop)
      end)
      return
    end

    vim.schedule(function()
      step(range_idx + 1)
    end)
  end

  vim.schedule(function()
    step(1)
  end)
end

local function decorate_buffer(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local transcript_stop = transcript_line_count(bufnr)
  local generation = cancel_deferred_decoration(bufnr)
  if transcript_stop <= 0 then
    return
  end

  normalize_transcript_display(bufnr)

  if transcript_stop <= DECORATE_SYNC_LINE_LIMIT or not buffer_is_visible(bufnr) then
    decorate_transcript_range(bufnr, 0, transcript_stop)
    diff_view.decorate_diff_blocks(bufnr)
    return
  end

  local visible_start, visible_stop = visible_transcript_range(bufnr)
  decorate_transcript_range(bufnr, visible_start, visible_stop)

  local ranges = {}
  if visible_start > 0 then
    ranges[#ranges + 1] = { 0, visible_start }
  end
  if visible_stop < transcript_stop then
    ranges[#ranges + 1] = { visible_stop, transcript_stop }
  end
  if #ranges > 0 then
    queue_deferred_transcript_decoration(bufnr, ranges, generation)
  end
  diff_view.decorate_diff_blocks(bufnr)
end

local function is_normal_window(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local ok, config = pcall(vim.api.nvim_win_get_config, win)
  return ok and config and config.relative == ""
end

local function resolve_anchor_window(win)
  if is_normal_window(win) then
    return win
  end
  local current = vim.api.nvim_get_current_win()
  if is_normal_window(current) then
    return current
  end
  return nil
end

local function to_bufnr(pane_id)
  local key = tostring(pane_id or "")
  local tracked = pane_buffers[key]
  if tracked and vim.api.nvim_buf_is_valid(tracked) then
    return tracked
  end
  pane_buffers[key] = nil

  local n = tonumber(pane_id)
  if n and vim.api.nvim_buf_is_valid(n) then
    pane_buffers[key] = n
    return n
  end
  return nil
end

local function buffer_var(bufnr, name)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local ok, value = pcall(vim.api.nvim_buf_get_var, bufnr, name)
  return ok and value or nil
end

pane_id_for_bufnr = function(bufnr)
  return buffer_var(bufnr, "lazyagent_acp_pane_id") or bufnr
end

agent_name_for_bufnr = function(bufnr)
  return buffer_var(bufnr, "lazyagent_acp_agent")
end

local function pane_opts_for_bufnr(bufnr)
  return pane_config[tostring(pane_id_for_bufnr(bufnr))] or {}
end

local function transcript_table_layout(bufnr)
  local opts = pane_opts_for_bufnr(bufnr)
  local layout = tostring(opts and opts.table_layout or ""):lower()
  if layout == "card" then
    return "card"
  end
  return "table"
end

fancy_mode_enabled = function(bufnr_or_pane_id)
  local opts
  if type(bufnr_or_pane_id) == "number" and vim.api.nvim_buf_is_valid(bufnr_or_pane_id) then
    opts = pane_opts_for_bufnr(bufnr_or_pane_id)
  else
    opts = pane_config[tostring(bufnr_or_pane_id or "")]
  end
  return type(opts) == "table" and opts.fancy_mode == true
end

local function should_release_buffer_on_hide(bufnr_or_pane_id)
  local opts
  if type(bufnr_or_pane_id) == "number" and vim.api.nvim_buf_is_valid(bufnr_or_pane_id) then
    opts = pane_opts_for_bufnr(bufnr_or_pane_id)
  else
    opts = pane_config[tostring(bufnr_or_pane_id or "")]
  end
  return type(opts) == "table" and opts.release_buffer_on_hide == true
end

local function resolve_release_buffer_on_hide(pane_opts, session)
  if type(pane_opts) == "table" and pane_opts.release_buffer_on_hide ~= nil then
    return pane_opts.release_buffer_on_hide == true
  end
  return session and session.release_buffer_on_hide == true or false
end

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

local function is_acp_buffer(bufnr)
  return buffer_var(bufnr, "lazyagent_acp_pane_id") ~= nil
end

local function tracked_transcript_window(win)
  local key = tostring(win or "")
  local entry = dedicated_transcript_windows[key]
  if entry == nil then
    return nil
  end
  if not win or not vim.api.nvim_win_is_valid(win) then
    dedicated_transcript_windows[key] = nil
    redirecting_transcript_windows[key] = nil
    return nil
  end
  return entry
end

local function track_transcript_window(win, pane_id, bufnr)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  dedicated_transcript_windows[tostring(win)] = {
    pane_id = tostring(pane_id),
    bufnr = bufnr,
  }
end

local function clear_transcript_window(win)
  local key = tostring(win or "")
  dedicated_transcript_windows[key] = nil
  redirecting_transcript_windows[key] = nil
end

local function reset_window_from_defaults(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  pcall(vim.api.nvim_win_call, win, function()
    for _, option in ipairs(ACP_WINDOW_OPTIONS) do
      pcall(vim.cmd, "setlocal " .. option .. "<")
    end
  end)
end

local function capture_window_options(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return nil
  end
  local snapshot = {}
  for _, option in ipairs(ACP_WINDOW_OPTIONS) do
    local ok, value = pcall(vim.api.nvim_get_option_value, option, { win = win })
    if ok then
      snapshot[option] = value
    end
  end
  return snapshot
end

local function apply_window_options(win, snapshot)
  if not win or not vim.api.nvim_win_is_valid(win) or type(snapshot) ~= "table" then
    return false
  end
  for _, option in ipairs(ACP_WINDOW_OPTIONS) do
    if snapshot[option] ~= nil then
      pcall(vim.api.nvim_set_option_value, option, snapshot[option], { win = win })
    end
  end
  return true
end

local function normalize_redirect_target_window(win, pane_opts)
  if apply_window_options(win, pane_opts and pane_opts.source_window_options) then
    return
  end
  reset_window_from_defaults(win)
end

local function restore_transcript_window_size(win, pane_opts)
  if not pane_opts or not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  set_window_size(win, pane_opts.pane_size, pane_opts.is_vertical == true)
end

local function usable_redirect_target(win, source_win)
  if not is_normal_window(win) or win == source_win or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  if tracked_transcript_window(win) ~= nil then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(win)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  local buftype = vim.bo[buf].buftype
  return buftype == "" or buftype == "acwrite"
end

local function find_redirect_target_window(source_win, pane_opts)
  local anchor = resolve_anchor_window(pane_opts and pane_opts.source_winid)
  if usable_redirect_target(anchor, source_win) then
    return anchor, false
  end

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if usable_redirect_target(win, source_win) then
      return win, false
    end
  end

  local created = nil
  pcall(function()
    vim.api.nvim_set_current_win(source_win)
    if pane_opts and pane_opts.is_vertical == true then
      vim.cmd("leftabove vsplit")
    else
      vim.cmd("leftabove split")
    end
    created = vim.api.nvim_get_current_win()
    normalize_redirect_target_window(created, pane_opts)
    restore_transcript_window_size(source_win, pane_opts)
  end)
  return created, created ~= nil
end

local function redirect_buffer_from_transcript_window(win, bufnr)
  if is_metadata_popup_buffer(bufnr) then
    return false
  end
  local tracked = tracked_transcript_window(win)
  if tracked == nil or tracked.bufnr == bufnr then
    return false
  end
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or is_acp_buffer(bufnr) then
    return false
  end

  local key = tostring(win)
  if redirecting_transcript_windows[key] then
    return false
  end

  local restore_buf = tracked.bufnr
  if not restore_buf or not vim.api.nvim_buf_is_valid(restore_buf) then
    restore_buf = to_bufnr(tracked.pane_id)
    if restore_buf and vim.api.nvim_buf_is_valid(restore_buf) then
      tracked.bufnr = restore_buf
    end
  end
  if not restore_buf or not vim.api.nvim_buf_is_valid(restore_buf) then
    clear_transcript_window(win)
    return false
  end

  redirecting_transcript_windows[key] = true
  local pane_opts = pane_config[tracked.pane_id] or pane_opts_for_bufnr(restore_buf)
  local target_win = select(1, find_redirect_target_window(win, pane_opts))
  if not target_win or not vim.api.nvim_win_is_valid(target_win) then
    redirecting_transcript_windows[key] = nil
    return false
  end

  pcall(vim.api.nvim_win_set_buf, target_win, bufnr)
  pcall(vim.api.nvim_win_set_buf, win, restore_buf)
  track_transcript_window(win, tracked.pane_id, restore_buf)
  if pane_config[tracked.pane_id] ~= nil then
    pane_config[tracked.pane_id].source_winid = target_win
    pane_config[tracked.pane_id].source_window_options = capture_window_options(target_win)
  end
  pcall(vim.api.nvim_set_current_win, target_win)
  redirecting_transcript_windows[key] = nil
  return true
end

layout_entry = function(bufnr)
  local key = tostring(bufnr)
  local entry = layout_state[key]
  if not entry then
    entry = {}
    layout_state[key] = entry
  end
  return entry
end

local function footer_padding_count(bufnr)
  return math.max(0, tonumber(layout_entry(bufnr).footer_padding_count) or 0)
end

local function background_group_name(base_group, bg)
  return "LazyAgentACP" .. tostring(base_group):gsub("[^%w]+", "") .. "Bg"
    .. tostring(bg):gsub("[^%w]+", "_")
end

local function window_background_group(base_group, bg)
  if not bg or bg == "" then
    return nil
  end

  local key = tostring(base_group) .. "\0" .. tostring(bg)
  local group = custom_background_groups[key] or background_group_name(base_group, bg)
  custom_background_groups[key] = group

  local spec = {}
  local ok, base = pcall(vim.api.nvim_get_hl, 0, { name = base_group, link = false })
  if ok and type(base) == "table" then
    spec = vim.deepcopy(base)
  end
  spec.bg = bg
  spec.default = nil
  spec.ctermbg = nil
  pcall(vim.api.nvim_set_hl, 0, group, spec)
  return group
end

local function apply_transcript_background(win, appearance)
  appearance = appearance or {}
  local active_bg = appearance.buffer_background
  local inactive_bg = appearance.buffer_inactive_background or active_bg

  local mappings = {}
  local active_group = window_background_group("Normal", active_bg)
  local inactive_group = window_background_group("NormalNC", inactive_bg)
  if active_group then
    mappings.Normal = active_group
    mappings.EndOfBuffer = active_group
  else
    mappings.EndOfBuffer = "None"
  end
  if inactive_group then
    mappings.NormalNC = inactive_group
  end
  if next(mappings) ~= nil then
    local current = vim.wo[win].winhighlight
    local merged = {}
    local order = {}
    for _, part in ipairs(vim.split(current or "", ",", { trimempty = true })) do
      local key, value = part:match("^([^:]+):(.+)$")
      if key and value then
        if merged[key] == nil then
          order[#order + 1] = key
        end
        merged[key] = value
      end
    end
    for key, value in pairs(mappings) do
      if merged[key] == nil then
        order[#order + 1] = key
      end
      merged[key] = value
    end
    local rendered = {}
    for _, key in ipairs(order) do
      rendered[#rendered + 1] = key .. ":" .. merged[key]
    end
    vim.wo[win].winhighlight = table.concat(rendered, ",")
  end
end

local function hide_end_of_buffer_fill(win)
  local current = vim.api.nvim_get_option_value("fillchars", { win = win })
  local parts = vim.split(current or "", ",", { trimempty = true })
  local filtered = {}
  for _, part in ipairs(parts) do
    if not vim.startswith(part, "eob:") then
      filtered[#filtered + 1] = part
    end
  end
  filtered[#filtered + 1] = "eob: "
  vim.api.nvim_set_option_value("fillchars", table.concat(filtered, ","), { win = win })
end

local function should_follow_output(bufnr)
  return pane_opts_for_bufnr(bufnr).follow_output ~= false
end

local function set_follow_output(bufnr, enabled)
  local pane_id = tostring(pane_id_for_bufnr(bufnr))
  pane_config[pane_id] = vim.tbl_extend("force", pane_config[pane_id] or {}, {
    follow_output = enabled ~= false,
  })
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(win) then
      vim.wo[win].scrolloff = (enabled ~= false) and FOLLOW_SCROLL_OFF or DEFAULT_SCROLL_OFF
    end
  end
end

local function pause_follow_output(bufnr)
  if not bufnr or not is_acp_buffer(bufnr) or not should_follow_output(bufnr) then
    return false
  end
  set_follow_output(bufnr, false)
  if type(M.refresh_footer) == "function" then
    M.refresh_footer(bufnr)
  end
  return true
end

set_window_size = function(win, size, is_vertical)
  local amount = tonumber(size)
  if not amount or amount <= 0 then
    return
  end
  if is_vertical then
    pcall(vim.api.nvim_win_set_width, win, math.max(10, amount))
  else
    pcall(vim.api.nvim_win_set_height, win, math.max(3, amount))
  end
end

local function apply_transcript_window_opts(win, is_vertical, appearance)
  pcall(function()
    suppress_transcript_window_refresh = true
    local bufnr = vim.api.nvim_win_get_buf(win)
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].cursorline = false
    vim.wo[win].wrap = true
    vim.wo[win].linebreak = true
    vim.wo[win].breakindent = true
    vim.wo[win].signcolumn = "no"
    vim.wo[win].statuscolumn = ""
    vim.wo[win].foldcolumn = "0"
    vim.wo[win].foldenable = false
    vim.wo[win].foldmethod = "manual"
    vim.wo[win].foldexpr = "0"
    vim.wo[win].winfixwidth = is_vertical == true
    vim.wo[win].winfixheight = is_vertical ~= true
    vim.wo[win].scrolloff = should_follow_output(bufnr) and FOLLOW_SCROLL_OFF or DEFAULT_SCROLL_OFF
    pcall(function()
      vim.wo[win].smoothscroll = true
    end)
    vim.wo[win].statusline = ""
    vim.wo[win].eventignorewin = ""
    hide_end_of_buffer_fill(win)
  end)
  pcall(apply_transcript_background, win, appearance)
  local bufnr = vim.api.nvim_win_get_buf(win)
  track_transcript_window(win, pane_id_for_bufnr(bufnr), bufnr)
  suppress_transcript_window_refresh = false
end

local function refresh_transcript_window(bufnr, win)
  if not bufnr or buffer_var(bufnr, "lazyagent_acp_pane_id") == nil then
    return
  end
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  if vim.api.nvim_win_get_buf(win) ~= bufnr then
    return
  end

  local opts = pane_opts_for_bufnr(bufnr)
  apply_transcript_window_opts(win, opts.is_vertical == true, opts)
end

local function apply_transcript_buffer_opts(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  pcall(function()
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].undofile = false
    vim.bo[bufnr].buflisted = false
    vim.b[bufnr].lazyagent_acp_transcript = true
    vim.b[bufnr].illuminate_disable = true
    vim.b[bufnr].matchup_matchparen_enabled = 0
  end)
  pcall(vim.api.nvim_set_option_value, "spell", false, { buf = bufnr })

  -- Buffer-local mappings: jump between User sections and fenced code blocks.
  local function jump_to_row(win, row)
    jump_window_to_row(win, row)
  end

  local function jump_to_user(forward)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    local win = vim.api.nvim_get_current_win()
    local cur = vim.api.nvim_win_get_cursor(win)
    local cur_row = cur[1]
    local stop = transcript_line_count(bufnr)
    if forward then
      for r = cur_row + 1, stop do
        local line = vim.api.nvim_buf_get_lines(bufnr, r - 1, r, false)[1] or ""
        if line_has_heading(line, "User") then
          jump_to_row(win, r)
          return
        end
      end
      vim.notify("No later User section", vim.log.levels.INFO)
    else
      for r = math.max(1, cur_row - 1), 1, -1 do
        local line = vim.api.nvim_buf_get_lines(bufnr, r - 1, r, false)[1] or ""
        if line_has_heading(line, "User") then
          jump_to_row(win, r)
          return
        end
      end
      vim.notify("No earlier User section", vim.log.levels.INFO)
    end
  end

  local function jump_to_code_block(forward)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    local win = vim.api.nvim_get_current_win()
    local cur = vim.api.nvim_win_get_cursor(win)
    local cur_row = cur[1]
    local stop = transcript_line_count(bufnr)
    local target = code_block_target_row(
      transcript_source_lines(bufnr, 0, stop),
      cur_row,
      forward
    )
    if target then
      jump_to_row(win, target)
      return
    end
    vim.notify(forward and "No later code block" or "No earlier code block", vim.log.levels.INFO)
  end

  pcall(function()
    vim.keymap.set("n", "]]", function()
      jump_to_user(true)
    end, { buffer = bufnr, noremap = true, silent = true, desc = "LazyAgentACP: next User" })
    vim.keymap.set("n", "[[", function()
      jump_to_user(false)
    end, { buffer = bufnr, noremap = true, silent = true, desc = "LazyAgentACP: prev User" })
    vim.keymap.set("n", "]d", function()
      jump_to_code_block(true)
    end, { buffer = bufnr, noremap = true, silent = true, desc = "LazyAgentACP: next code block" })
    vim.keymap.set("n", "[d", function()
      jump_to_code_block(false)
    end, { buffer = bufnr, noremap = true, silent = true, desc = "LazyAgentACP: prev code block" })
    vim.keymap.set("n", "<C-u>", function()
      M.scroll_up(pane_id_for_bufnr(bufnr))
    end, { buffer = bufnr, noremap = true, silent = true, desc = "LazyAgentACP: half page up" })
    vim.keymap.set("n", "<C-d>", function()
      M.scroll_down(pane_id_for_bufnr(bufnr))
    end, { buffer = bufnr, noremap = true, silent = true, desc = "LazyAgentACP: half page down" })
    vim.keymap.set("n", "<CR>", function()
      if diff_view and type(diff_view.open_diff_block_under_cursor) == "function" then
        local ok, opened = pcall(diff_view.open_diff_block_under_cursor, bufnr)
        if ok and opened then
          return
        end
        if not ok then
          vim.notify("LazyAgentACP: failed to open diff block", vim.log.levels.WARN)
          return
        end
      end
      vim.cmd("normal! <CR>")
    end, { buffer = bufnr, noremap = true, silent = true, desc = "LazyAgentACP: open diff block" })
    vim.keymap.set("n", "ga", function()
      show_action_menu(vim.api.nvim_get_current_buf())
    end, { buffer = bufnr, noremap = true, silent = true, desc = "LazyAgentACP: actions" })
    vim.keymap.set("n", "<Space><Space>", function()
      show_metadata_popup(vim.api.nvim_get_current_buf())
    end, { buffer = bufnr, noremap = true, silent = true, desc = "LazyAgentACP: show metadata" })
    vim.keymap.set("n", "<LocalLeader>s", function()
      require("lazyagent.logic.session").switch_acp_provider(agent_name_for_bufnr(vim.api.nvim_get_current_buf()))
    end, { buffer = bufnr, noremap = true, silent = true, desc = "LazyAgentACP: switch provider" })
  end)

end

local function close_buffer_windows(bufnr)
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
end

local function save_window_views(bufnr)
  local views = {}
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return views
  end

  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(win) then
      local ok, view = pcall(vim.api.nvim_win_call, win, function()
        return vim.fn.winsaveview()
      end)
      if ok and type(view) == "table" then
        views[tostring(win)] = view
      end
    end
  end
  return views
end

local function restore_window_views(bufnr, views)
  if type(views) ~= "table" or not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local line_count = math.max(1, vim.api.nvim_buf_line_count(bufnr))
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    local view = views[tostring(win)]
    if vim.api.nvim_win_is_valid(win) and type(view) == "table" and vim.api.nvim_win_get_buf(win) == bufnr then
      pcall(vim.api.nvim_win_call, win, function()
        local restored = vim.deepcopy(view)
        restored.lnum = math.min(math.max(1, tonumber(restored.lnum) or 1), line_count)
        restored.topline = math.min(math.max(1, tonumber(restored.topline) or 1), line_count)
        vim.fn.winrestview(restored)
      end)
    end
  end
end

local function release_transcript_buffer(pane_id, bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  cleanup_markdown_rendering(bufnr)
  layout_state[tostring(bufnr)] = nil
  if pane_buffers[tostring(pane_id)] == bufnr then
    pane_buffers[tostring(pane_id)] = nil
  end
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  return true
end

local function create_transcript_buffer(pane_id, agent_name, transcript_path)
  local bufnr = vim.api.nvim_create_buf(false, true)
  local safe_agent_name = tostring(agent_name or "agent"):gsub("[^%w-_]+", "-")
  local pane_key = tostring(pane_id)

  pcall(function()
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "hide"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].buflisted = false
    vim.bo[bufnr].undofile = false
    vim.b[bufnr].lazyagent_acp_transcript = true
    vim.bo[bufnr].filetype = ACP_TRANSCRIPT_FILETYPE
    vim.api.nvim_buf_set_name(bufnr, string.format("lazyagent://acp/%s-%s", safe_agent_name, pane_key))
    vim.b[bufnr].lazyagent_acp_pane_id = pane_key
    vim.b[bufnr].lazyagent_acp_agent = agent_name
    vim.b[bufnr].lazyagent_acp_transcript_path = transcript_path
  end)
  apply_transcript_buffer_opts(bufnr)

  pane_buffers[pane_key] = bufnr
  return bufnr
end

local function adopt_transcript_buffer(pane_id, agent_name, transcript_path, switch_view)
  if type(switch_view) ~= "table" then
    return nil
  end

  local bufnr = tonumber(switch_view.bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local pane_key = tostring(pane_id)
  local old_pane_key = tostring(switch_view.pane_id or buffer_var(bufnr, "lazyagent_acp_pane_id") or "")
  if old_pane_key ~= "" then
    if pane_buffers[old_pane_key] == bufnr then
      pane_buffers[old_pane_key] = nil
    end
    pane_config[old_pane_key] = nil
  end

  local safe_agent_name = tostring(agent_name or "agent"):gsub("[^%w-_]+", "-")
  pcall(function()
    vim.api.nvim_buf_set_name(bufnr, "")
    vim.api.nvim_buf_set_name(bufnr, string.format("lazyagent://acp/%s-%s", safe_agent_name, pane_key))
    vim.b[bufnr].lazyagent_acp_pane_id = pane_key
    vim.b[bufnr].lazyagent_acp_agent = agent_name
    vim.b[bufnr].lazyagent_acp_transcript_path = transcript_path
  end)

  local entry = layout_entry(bufnr)
  entry.footer_signature = nil
  entry.pending_full_refresh = false
  entry.transcript_file_signature = nil

  pane_buffers[pane_key] = bufnr
  apply_transcript_buffer_opts(bufnr)
  return bufnr
end

first_visible_window = function(bufnr)
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(win) then
      return win
    end
  end
  return nil
end

buffer_is_visible = function(bufnr)
  return first_visible_window(bufnr) ~= nil
end

transcript_max_lines = function(bufnr)
  local opts = pane_opts_for_bufnr(bufnr)
  local value = tonumber(opts and opts.transcript_max_lines)
  if value and value > 0 then
    return math.floor(value)
  end
  return nil
end

local function transcript_compaction_config(bufnr)
  local opts = pane_opts_for_bufnr(bufnr)
  local cfg = type(opts and opts.transcript_compaction) == "table" and opts.transcript_compaction or {}
  local min_sections = tonumber(cfg.min_sections) or 48
  local keep_recent_sections = tonumber(cfg.keep_recent_sections) or 24
  local summary_items = tonumber(cfg.summary_items) or 6
  return {
    enabled = cfg.enabled == true,
    min_sections = math.max(2, math.floor(min_sections)),
    keep_recent_sections = math.max(1, math.floor(keep_recent_sections)),
    summary_items = math.max(1, math.floor(summary_items)),
  }
end

local function section_chunk_stop(sections, idx, total_lines)
  if idx < #sections then
    return math.max(sections[idx].end_row, sections[idx + 1].start_row - 1)
  end
  return math.max(sections[idx].end_row, total_lines)
end

local function append_line_range(target, source, start_row, stop_row)
  for row = start_row, stop_row do
    target[#target + 1] = source[row] or ""
  end
end

local function summarize_compacted_text(text, limit)
  text = tostring(text or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  limit = tonumber(limit) or 120
  if text == "" then
    return ""
  end
  if #text <= limit then
    return text
  end
  return text:sub(1, math.max(1, limit - 1)) .. "…"
end

local function section_summary_text(lines, section)
  if type(section) ~= "table" then
    return ""
  end
  for row = section.start_row + 1, section.end_row do
    local text = summarize_compacted_text((lines[row] or ""):gsub("^%s+", ""), 120)
    if text ~= "" then
      return text
    end
  end
  return ""
end

local function transcript_items_for_sections(bufnr, sections)
  local items = {}
  local timeline = runtime_conversation_timeline(bufnr)
  local offset = math.max(#timeline - #sections, 0)
  for idx = 1, #sections do
    items[idx] = timeline[offset + idx]
  end
  return items
end

pinned_section_rows = function(bufnr, lines)
  lines = type(lines) == "table" and lines or {}
  local sections = collect_transcript_sections(lines)
  if #sections == 0 then
    return {}
  end

  local entry = layout_entry(bufnr)
  local items = type(entry.transcript_section_items) == "table" and entry.transcript_section_items or nil
  if type(items) ~= "table" or #items ~= #sections then
    items = transcript_items_for_sections(bufnr, sections)
  end

  local pinned_rows = {}
  for idx, section in ipairs(sections) do
    if type(items[idx]) == "table" and items[idx].pinned == true then
      pinned_rows[section.start_row] = true
    end
  end

  return pinned_rows
end

local function with_transcript_display_meta(meta, sections, compacted, lines)
  meta = type(meta) == "table" and meta or {}
  meta.raw_section_count = #(sections or {})
  meta.compacted = compacted == true
  meta.table_tail_state = trailing_markdown_table_context(lines).state
  return meta
end

local function compacted_block_body(bufnr, lines, sections, items, cfg)
  local counts = {}
  local ordered_counts = {}
  local highlights = {}
  local seen_highlights = {}
  local fancy = fancy_mode_enabled(bufnr)

  for idx, section in ipairs(sections) do
    local item = items[idx]
    local label = (item and item.heading) or section.heading or "Section"
    if counts[label] == nil then
      ordered_counts[#ordered_counts + 1] = label
      counts[label] = 0
    end
    counts[label] = counts[label] + 1

    local summary = summarize_compacted_text(item and item.summary or section_summary_text(lines, section), 120)
    if summary ~= "" and not seen_highlights[summary] and #highlights < cfg.summary_items then
      seen_highlights[summary] = true
      highlights[#highlights + 1] = summary
    end
  end

  local body = {
    fancy
        and string.format("🎉✨ Earlier transcript compacted (%d sections). ✨🎉", #sections)
      or string.format("Earlier transcript compacted (%d sections).", #sections),
  }

  if #ordered_counts > 0 then
    local parts = {}
    for _, label in ipairs(ordered_counts) do
      parts[#parts + 1] = string.format("%s x%d", label, counts[label])
    end
    body[#body + 1] = (fancy and "🎈 " or "- ") .. table.concat(parts, ", ")
  end

  for _, highlight in ipairs(highlights) do
    body[#body + 1] = (fancy and "🌟 " or "- ") .. highlight
  end

  return body
end

local function compacted_section_lines(bufnr, lines, sections, items, cfg)
  local body = compacted_block_body(bufnr, lines, sections, items, cfg)
  local rendered = { "─ System" }
  for _, line in ipairs(body) do
    rendered[#rendered + 1] = " " .. line
  end
  rendered[#rendered + 1] = ""
  local start_row = sections[1] and sections[1].start_row or 1
  local stop_row = sections[#sections] and section_chunk_stop(sections, #sections, #lines) or start_row
  return rendered, {
    kind = "compacted",
    heading = "System",
    title = "Compacted earlier transcript",
    summary = string.format("%d sections compacted", #sections),
    compacted_section_count = #sections,
    compacted_relative_start_row = start_row,
    compacted_relative_stop_row = stop_row,
    compacted_max_lines = transcript_max_lines(bufnr),
  }
end

local function compact_transcript_lines(bufnr, raw_lines)
  raw_lines = type(raw_lines) == "table" and raw_lines or {}
  local cfg = transcript_compaction_config(bufnr)
  local sections = collect_transcript_sections(raw_lines)
  local items = transcript_items_for_sections(bufnr, sections)
  if not cfg.enabled or #sections < cfg.min_sections then
    local transformed, _, meta = transform_markdown_tables(raw_lines, transcript_table_layout(bufnr))
    return transformed, items, with_transcript_display_meta(meta, sections, false, raw_lines)
  end

  local keep_recent = math.min(#sections, cfg.keep_recent_sections)
  local compact_limit = #sections - keep_recent
  if compact_limit < 2 then
    local transformed, _, meta = transform_markdown_tables(raw_lines, transcript_table_layout(bufnr))
    return transformed, items, with_transcript_display_meta(meta, sections, false, raw_lines)
  end

  local out_lines = {}
  local out_items = {}
  if raw_lines[1] == TRANSCRIPT_TRUNCATED_MARKER then
    out_lines[#out_lines + 1] = TRANSCRIPT_TRUNCATED_MARKER
  end

  local idx = 1
  while idx <= #sections do
    local item = items[idx]
    if idx <= compact_limit and not (item and item.pinned == true) then
      local group_start = idx
      while idx <= compact_limit and not (items[idx] and items[idx].pinned == true) do
        idx = idx + 1
      end
      local group_end = idx - 1
      if group_end - group_start + 1 >= 2 then
        local group_sections = vim.list_slice(sections, group_start, group_end)
        local group_items = vim.list_slice(items, group_start, group_end)
        local rendered, synthetic_item = compacted_section_lines(bufnr, raw_lines, group_sections, group_items, cfg)
        vim.list_extend(out_lines, rendered)
        out_items[#out_items + 1] = synthetic_item
      else
        append_line_range(out_lines, raw_lines, sections[group_start].start_row, section_chunk_stop(sections, group_start, #raw_lines))
        out_items[#out_items + 1] = items[group_start]
      end
    else
      append_line_range(out_lines, raw_lines, sections[idx].start_row, section_chunk_stop(sections, idx, #raw_lines))
      out_items[#out_items + 1] = item
      idx = idx + 1
    end
  end

  local transformed, _, meta = transform_markdown_tables(out_lines, transcript_table_layout(bufnr))
  return transformed, out_items, with_transcript_display_meta(meta, sections, true, raw_lines)
end

read_transcript_lines = function(path, max_lines)
  if not path or path == "" or vim.fn.filereadable(path) ~= 1 then
    return {}
  end

  max_lines = tonumber(max_lines)
  if max_lines and max_lines > 0 and vim.fn.executable("tail") == 1 then
    local data = vim.fn.systemlist({ "tail", "-n", tostring(max_lines + 1), path })
    if vim.v.shell_error == 0 and type(data) == "table" then
      if #data > max_lines then
        data = vim.list_slice(data, #data - max_lines + 1, #data)
        table.insert(data, 1, TRANSCRIPT_TRUNCATED_MARKER)
      end
      return data
    end
  end

  local ok, data = pcall(vim.fn.readfile, path)
  if not ok or not data then
    return {}
  end
  if max_lines and max_lines > 0 and #data > max_lines then
    data = vim.list_slice(data, #data - max_lines + 1, #data)
    table.insert(data, 1, TRANSCRIPT_TRUNCATED_MARKER)
  end
  return data
end

local function transcript_file_signature(path)
  if not path or path == "" then
    return ""
  end

  local stat = vim.loop.fs_stat(path)
  if not stat then
    return ""
  end

  local mtime = stat.mtime or {}
  return table.concat({
    tostring(stat.size or 0),
    tostring(mtime.sec or 0),
    tostring(mtime.nsec or 0),
  }, ":")
end

set_buffer_lines = function(bufnr, lines, section_items, display_meta)
  local entry = layout_entry(bufnr)
  entry.footer_padding_count = 0
  entry.footer_signature = nil
  entry.transcript_source_lines = lines or {}
  entry.transcript_section_items = section_items or {}
  entry.transcript_display_meta = display_meta or {}
  replace_buffer_lines(bufnr, 0, -1, lines)
end

replace_buffer_lines = function(bufnr, start_idx, end_idx, lines)
  local original_modifiable = vim.bo[bufnr].modifiable
  vim.bo[bufnr].modifiable = true
  pcall(vim.api.nvim_buf_set_lines, bufnr, start_idx, end_idx, false, lines)
  vim.bo[bufnr].modifiable = original_modifiable
end

local function set_footer_padding(bufnr, count)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local entry = layout_entry(bufnr)
  local current = footer_padding_count(bufnr)
  local target = math.max(0, tonumber(count) or 0)
  if current == target then
    return
  end

  local transcript_stop = transcript_line_count(bufnr)
  local padding = {}
  for _ = 1, target do
    padding[#padding + 1] = ""
  end
  replace_buffer_lines(bufnr, transcript_stop, -1, padding)
  entry.footer_padding_count = target
end

local function ensure_layout_autocmds()
  if layout_autocmds_initialized then
    return
  end
  layout_autocmds_initialized = true

  local group = vim.api.nvim_create_augroup("LazyAgentACPLayout", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = ACP_TRANSCRIPT_FILETYPE,
    callback = function(args)
      apply_transcript_buffer_opts(tonumber(args.buf))
    end,
  })

  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = group,
    callback = function()
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if buffer_var(bufnr, "lazyagent_acp_pane_id") ~= nil and first_visible_window(bufnr) then
          for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
            if vim.api.nvim_win_is_valid(win) then
              local opts = pane_opts_for_bufnr(bufnr)
              apply_transcript_window_opts(win, opts.is_vertical == true, opts)
            end
          end
          pcall(refresh_buffer_layout, bufnr)
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function(args)
      local bufnr = tonumber(args.buf)
      if not bufnr then
        return
      end
      if is_metadata_popup_buffer(bufnr) then
        return
      end
      if redirect_buffer_from_transcript_window(vim.api.nvim_get_current_win(), bufnr) then
        return
      end
      if not is_acp_buffer(bufnr) then
        return
      end
      apply_transcript_buffer_opts(bufnr)
      for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
        refresh_transcript_window(bufnr, win)
      end
      if layout_entry(bufnr).pending_full_refresh then
        pcall(refresh_buffer_from_path, bufnr, buffer_var(bufnr, "lazyagent_acp_transcript_path"))
      else
        pcall(refresh_buffer_layout, bufnr)
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(args)
      local bufnr = tonumber(args.buf)
      if not bufnr then
        return
      end
      if is_metadata_popup_buffer(bufnr) then
        return
      end
      if is_acp_buffer(bufnr) then
        pause_follow_output(bufnr)
        refresh_transcript_window(bufnr, vim.api.nvim_get_current_win())
        return
      end
      redirect_buffer_from_transcript_window(vim.api.nvim_get_current_win(), bufnr)
    end,
  })

  vim.api.nvim_create_autocmd("WinEnter", {
    group = group,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      local bufnr = vim.api.nvim_get_current_buf()
      if is_metadata_popup_buffer(bufnr) then
        return
      end
      if is_acp_buffer(bufnr) then
        pause_follow_output(bufnr)
        refresh_transcript_window(bufnr, win)
        return
      end
      redirect_buffer_from_transcript_window(win, bufnr)
    end,
  })

  vim.api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = { "fillchars", "winhighlight", "foldenable", "foldmethod", "foldexpr", "foldcolumn" },
    callback = function()
      if suppress_transcript_window_refresh then
        return
      end
      local win = vim.api.nvim_get_current_win()
      local bufnr = vim.api.nvim_get_current_buf()
      if not bufnr or buffer_var(bufnr, "lazyagent_acp_pane_id") == nil then
        return
      end
      vim.schedule(function()
        refresh_transcript_window(bufnr, win)
      end)
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(args)
      local bufnr = tonumber(args.buf)
      if not bufnr then
        return
      end
      local pane_id = buffer_var(bufnr, "lazyagent_acp_pane_id")
      cleanup_markdown_rendering(bufnr)
      if pane_id ~= nil and pane_buffers[tostring(pane_id)] == bufnr then
        pane_buffers[tostring(pane_id)] = nil
      end
      layout_state[tostring(bufnr)] = nil
      for key, entry in pairs(dedicated_transcript_windows) do
        if entry.bufnr == bufnr or tostring(entry.pane_id or "") == tostring(pane_id or "") then
          dedicated_transcript_windows[key] = nil
          redirecting_transcript_windows[key] = nil
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(args)
      clear_transcript_window(tonumber(args.match))
    end,
  })

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      highlights_defined = false
      custom_background_groups = {}
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if buffer_var(bufnr, "lazyagent_acp_pane_id") ~= nil and first_visible_window(bufnr) then
          for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
            if vim.api.nvim_win_is_valid(win) then
              local opts = pane_opts_for_bufnr(bufnr)
              apply_transcript_window_opts(win, opts.is_vertical == true, opts)
            end
          end
          pcall(refresh_buffer_layout, bufnr, { force_decorate = true, force_footer = true })
        end
      end
    end,
  })
end

scroll_buffer_to_end = function(bufnr)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if line_count <= 0 then
    return
  end
  local last_line = vim.api.nvim_buf_get_lines(bufnr, line_count - 1, line_count, false)[1] or ""
  local row = math.max(1, line_count)
  local col = math.max(0, #last_line)
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_call, win, function()
        vim.wo[win].scrolloff = FOLLOW_SCROLL_OFF
        vim.api.nvim_win_set_cursor(win, { row, col })
        vim.cmd("silent! normal! zb")
      end)
    end
  end
end

transcript_line_count = function(bufnr)
  local count = math.max(0, vim.api.nvim_buf_line_count(bufnr) - footer_padding_count(bufnr))
  if count == 1 then
    local first = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ""
    if first == "" then
      return 0
    end
  end
  return count
end

local function append_text_to_buffer(bufnr, text, opts)
  if not text or text == "" or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  opts = opts or {}

  local entry = layout_entry(bufnr)
  local current_display_meta = type(entry.transcript_display_meta) == "table" and entry.transcript_display_meta or {}
  local preserved_section_items = opts.preserve_display_metadata == true and entry.transcript_section_items or nil
  local preserved_display_meta = opts.preserve_display_metadata == true and current_display_meta or nil
  local raw_lines = type(entry.transcript_source_lines) == "table" and entry.transcript_source_lines or {}
  local transcript_stop = transcript_line_count(bufnr)
  local replace_start = transcript_stop
  local current_last = ""
  if transcript_stop > 0 then
    replace_start = transcript_stop - 1
    current_last = raw_lines[transcript_stop] or ""
  end
  set_footer_padding(bufnr, 0)
  entry.footer_signature = nil
  local total_lines = vim.api.nvim_buf_line_count(bufnr)

  local chunks = vim.split(text, "\n", { plain = true })
  local replacement = { current_last .. table.remove(chunks, 1) }
  vim.list_extend(replacement, chunks)

  local new_raw = {}
  for idx = 1, replace_start do
    new_raw[#new_raw + 1] = raw_lines[idx]
  end
  vim.list_extend(new_raw, replacement)
  local next_meta = vim.deepcopy(current_display_meta)
  if type(next_meta) ~= "table" then
    next_meta = {}
  end
  if type(preserved_display_meta) ~= "table" then
    next_meta.compacted = false
  end
  next_meta.table_tail_state = trailing_markdown_table_context(new_raw).state
  entry.transcript_source_lines = new_raw
  entry.transcript_section_items = preserved_section_items or {}
  entry.transcript_display_meta = next_meta

  replace_buffer_lines(bufnr, replace_start, total_lines, replacement)
  return replace_start
end

local function pending_transcript_section_count(text)
  local count = 0
  for _, line in ipairs(vim.split(tostring(text or ""), "\n", { plain = true })) do
    if section_heading_for_line(line) then
      count = count + 1
    end
  end
  return count
end

local function text_has_markdown_table_candidate(text)
  local lines = vim.split(tostring(text or ""), "\n", { plain = true })
  for idx, line in ipairs(lines) do
    local _, headers = split_markdown_table_cells(line)
    if headers and is_markdown_table_separator(lines[idx + 1], #headers) then
      return true
    end
    if is_markdown_table_separator(line) then
      return true
    end
  end
  return false
end

local function append_requires_full_refresh(bufnr, text)
  local entry = layout_entry(bufnr)
  local meta = type(entry.transcript_display_meta) == "table" and entry.transcript_display_meta or {}
  local cfg = transcript_compaction_config(bufnr)
  local has_table_candidate = false
  if transcript_table_layout(bufnr) == "card" then
    local table_state = tostring(meta.table_tail_state or "none")
    if table_state == "rows" or text_has_markdown_table_candidate(text) then
      has_table_candidate = true
    elseif table_state == "header" or table_state == "separator" then
      local tail_context = trailing_markdown_table_context(entry.transcript_source_lines).lines
      if #tail_context > 0 then
        local combined = vim.deepcopy(tail_context)
        vim.list_extend(combined, vim.split(tostring(text or ""), "\n", { plain = true }))
        has_table_candidate = text_has_markdown_table_candidate(table.concat(combined, "\n"))
      end
    end
  end
  if cfg.enabled then
    local pending_sections = pending_transcript_section_count(text)
    if meta.compacted == true then
      return pending_sections > 0 or has_table_candidate
    end
    local section_count = tonumber(meta.raw_section_count) or 0
    if section_count + pending_sections >= cfg.min_sections then
      return true
    end
  end

  return has_table_candidate
end

refresh_buffer_from_path = function(bufnr, transcript_path, opts)
  opts = opts or {}
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  local entry = layout_entry(bufnr)
  local saved_views = nil
  if opts.preserve_view ~= false and not should_follow_output(bufnr) then
    saved_views = save_window_views(bufnr)
  end
  local signature = transcript_file_signature(transcript_path)
  if not opts.force and entry.transcript_file_signature == signature then
    entry.pending_full_refresh = false
    refresh_buffer_layout(bufnr, opts.layout or {})
    restore_window_views(bufnr, saved_views)
    return false
  end

  local lines = read_transcript_lines(transcript_path, transcript_max_lines(bufnr))
  local display_lines, section_items, display_meta = compact_transcript_lines(bufnr, lines)

  set_buffer_lines(bufnr, display_lines, section_items, display_meta)
  entry.pending_full_refresh = false
  entry.transcript_file_signature = signature
  refresh_buffer_layout(bufnr, { force_decorate = true, force_footer = true })
  restore_window_views(bufnr, saved_views)
  return true
end

local function refresh_buffer_from_file(session)
  local bufnr = to_bufnr(session and session.pane_id)
  if not bufnr then
    return
  end

  session.view_state = session.view_state or {}
  local view_state = session.view_state
  if view_state.refresh_pending then
    return
  end
  view_state.refresh_pending = true

  vim.schedule(function()
    view_state.refresh_pending = false
    if not vim.api.nvim_buf_is_valid(bufnr) then
      view_state.force_full_refresh = false
      return
    end

    if not buffer_is_visible(bufnr) then
      layout_entry(bufnr).pending_full_refresh = true
      view_state.force_full_refresh = false
      return
    end

    refresh_buffer_from_path(bufnr, session.transcript_path)
    view_state.force_full_refresh = false
  end)
end

local function queue_append(session, text)
  local bufnr = to_bufnr(session and session.pane_id)
  if not bufnr then
    return
  end

  session.view_state = session.view_state or {}
  session.view_state.pending_append = (session.view_state.pending_append or "") .. tostring(text or "")

  local function flush_pending_append()
    close_timer(session.view_state.append_timer)
    session.view_state.append_timer = nil
    if not vim.api.nvim_buf_is_valid(bufnr) then
      session.view_state.pending_append = ""
      return
    end
    local pending = session.view_state.pending_append or ""
    session.view_state.pending_append = ""
    if pending == "" then
      return
    end
    if not buffer_is_visible(bufnr) then
      layout_entry(bufnr).pending_full_refresh = true
      return
    end
    local changed_start = nil
    local pending_sections = pending_transcript_section_count(pending)
    if append_requires_full_refresh(bufnr, pending) then
      refresh_buffer_from_path(bufnr, session.transcript_path, { force = true })
    else
      local entry = layout_entry(bufnr)
      local meta = type(entry.transcript_display_meta) == "table" and entry.transcript_display_meta or {}
      local preserve_display_metadata = meta.compacted == true and pending_sections == 0
      changed_start = append_text_to_buffer(bufnr, pending, {
        preserve_display_metadata = preserve_display_metadata,
      })
      if changed_start ~= nil then
        local meta = type(entry.transcript_display_meta) == "table" and entry.transcript_display_meta or {}
        meta.raw_section_count = (tonumber(meta.raw_section_count) or 0) + pending_sections
        entry.transcript_display_meta = meta
      end
    end
    local max_lines = transcript_max_lines(bufnr)
    if max_lines and max_lines > 0 and transcript_line_count(bufnr) > (max_lines + 1) then
      refresh_buffer_from_path(bufnr, session.transcript_path)
    elseif changed_start ~= nil then
      local display_start = normalize_transcript_display(bufnr)
      if type(display_start) == "number" then
        changed_start = math.min(changed_start, display_start)
      end
      decorate_transcript_range(bufnr, changed_start, transcript_line_count(bufnr))
      diff_view.decorate_diff_blocks(bufnr)
    end
    layout_entry(bufnr).transcript_file_signature = transcript_file_signature(session.transcript_path)
    M.refresh_footer(bufnr)
    if should_follow_output(bufnr) then
      scroll_buffer_to_end(bufnr)
    end
  end

  if session.view_state.append_timer then
    return
  end

  local uv = vim.uv or vim.loop
  if not uv or not uv.new_timer then
    vim.schedule(flush_pending_append)
    return
  end

  local timer = uv.new_timer()
  session.view_state.append_timer = timer
  timer:start(APPEND_BATCH_MS, 0, vim.schedule_wrap(flush_pending_append))
end

diff_view = view_diff.new({
  diff_utils = require("lazyagent.acp.diff"),
  diff_ns = diff_ns,
  session_for_agent = session_for_agent,
  transcript_line_count = function(bufnr)
    return transcript_line_count(bufnr)
  end,
  transcript_lines = function(bufnr, start_idx, end_idx)
    return transcript_source_lines(bufnr, start_idx, end_idx)
  end,
  agent_name_for_bufnr = agent_name_for_bufnr,
})

footer_view = view_footer.new({
  agent_logic = agent_logic,
  state = state,
  footer_ns = footer_ns,
  session_for_agent = session_for_agent,
  agent_name_for_bufnr = agent_name_for_bufnr,
  transcript_line_count = function(bufnr)
    return transcript_line_count(bufnr)
  end,
  overlay_target_width = overlay_target_width,
  layout_entry = layout_entry,
  footer_padding_count = footer_padding_count,
  set_footer_padding = set_footer_padding,
  buffer_is_visible = function(bufnr)
    return buffer_is_visible(bufnr)
  end,
  is_acp_buffer = is_acp_buffer,
})

function M.statusline()
  return footer_view.statusline()
end

function M.refresh_footer(bufnr, opts)
  return footer_view.refresh_footer(bufnr, opts)
end

refresh_buffer_layout = function(bufnr, opts)
  opts = opts or {}
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  if buffer_var(bufnr, "lazyagent_acp_pane_id") == nil then
    return false
  end

  local entry = layout_entry(bufnr)
  local header_width = header_target_width(bufnr) or 0
  local footer_width = overlay_target_width(bufnr)
  local transcript_count = transcript_line_count(bufnr)
  local decorate_needed = opts.force_decorate == true
    or entry.transcript_count ~= transcript_count
    or entry.header_width ~= header_width
  local footer_needed = opts.force_footer == true
    or decorate_needed
    or entry.footer_width ~= footer_width

  entry.header_width = header_width
  entry.footer_width = footer_width
  entry.transcript_count = transcript_count

  if decorate_needed then
    decorate_buffer(bufnr)
  end
  if footer_needed then
    M.refresh_footer(bufnr, { force = opts.force_footer == true or decorate_needed })
  end
  if should_follow_output(bufnr) then
    scroll_buffer_to_end(bufnr)
  end
  refresh_markdown_rendering(bufnr)
  return decorate_needed or footer_needed
end

function M.refresh_all_footers()
  return footer_view.refresh_all_footers()
end

function M.refresh_agent_footers(agent_name, opts)
  return footer_view.refresh_agent_footers(agent_name, opts)
end

function M.capture_switch_view(pane_id)
  ensure_layout_autocmds()
  local bufnr = to_bufnr(pane_id)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local windows = {}
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(win) then
      windows[#windows + 1] = win
    end
  end
  if #windows == 0 then
    return nil
  end

  return {
    pane_id = tostring(pane_id),
    bufnr = bufnr,
    windows = windows,
    views = save_window_views(bufnr),
    pane_config = vim.deepcopy(pane_config[tostring(pane_id)] or {}),
  }
end

function M.create_pane(args, on_split)
  ensure_layout_autocmds()
  local anchor_win = resolve_anchor_window(args.acp and args.acp.source_winid)
  next_pane_seq = next_pane_seq + 1
  local pane_id = string.format("buffer-acp-%d", next_pane_seq)
  local agent_name = (args.acp or {}).agent_name or "agent"
  local switch_view = args.acp and args.acp.reuse_view or nil
  local bufnr = adopt_transcript_buffer(pane_id, agent_name, args.transcript_path, switch_view)
  local reused_view = bufnr ~= nil

  local base_pane_config = reused_view and type(switch_view) == "table" and switch_view.pane_config or nil
  local inherited_follow_output = true
  if reused_view and type(base_pane_config) == "table" and base_pane_config.follow_output == false then
    inherited_follow_output = false
  end
  pane_config[pane_id] = vim.tbl_extend("force", base_pane_config or pane_config[pane_id] or {}, {
    source_winid = anchor_win,
    source_window_options = capture_window_options(anchor_win),
    pane_size = args.size,
    is_vertical = args.is_vertical == true,
    follow_output = inherited_follow_output,
    buffer_background = args.acp and args.acp.buffer_background or nil,
    buffer_inactive_background = args.acp and args.acp.buffer_inactive_background or nil,
    table_layout = args.acp and args.acp.table_layout or "table",
    fancy_mode = args.acp and args.acp.fancy_mode == true,
    release_buffer_on_hide = args.acp and args.acp.release_buffer_on_hide == true,
    transcript_max_lines = args.acp and args.acp.transcript_max_lines or nil,
    transcript_compaction = vim.deepcopy(args.acp and args.acp.transcript_compaction or {}),
  })

  local win = bufnr and first_visible_window(bufnr) or nil
  if reused_view and win then
    for _, visible_win in ipairs(vim.fn.win_findbuf(bufnr)) do
      if vim.api.nvim_win_is_valid(visible_win) then
        apply_transcript_window_opts(visible_win, args.is_vertical, pane_config[pane_id])
      end
    end
    refresh_buffer_layout(bufnr, { force_decorate = true, force_footer = true })
    restore_window_views(bufnr, switch_view and switch_view.views or nil)
  else
    if anchor_win then
      pcall(vim.api.nvim_set_current_win, anchor_win)
    end

    if args.is_vertical then
      vim.cmd("vsplit")
    else
      vim.cmd("split")
    end

    win = vim.api.nvim_get_current_win()
    set_window_size(win, args.size, args.is_vertical)
    bufnr = create_transcript_buffer(pane_id, agent_name, args.transcript_path)
    vim.api.nvim_win_set_buf(win, bufnr)
    apply_transcript_window_opts(win, args.is_vertical, pane_config[pane_id])
    refresh_buffer_from_path(bufnr, args.transcript_path, { force = true })
  end

  if anchor_win and anchor_win ~= win then
    pcall(vim.api.nvim_set_current_win, anchor_win)
  end

  if on_split then
    vim.schedule(function()
      on_split(pane_id, {
        bufnr = bufnr,
        winid = win,
        source_winid = anchor_win,
        preserve_existing_transcript = reused_view == true,
      })
    end)
  end
end

function M.on_session_created(session)
  local bufnr = to_bufnr(session and session.pane_id)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(function()
      vim.b[bufnr].lazyagent_acp_pane_id = tostring(session.pane_id)
      vim.b[bufnr].lazyagent_acp_agent = session.agent_name
      vim.b[bufnr].lazyagent_acp_transcript_path = session.transcript_path
    end)
    refresh_buffer_layout(bufnr, { force_footer = true })
  end
  if session and session.view_state and session.view_state.preserve_existing_transcript == true then
    return
  end
  refresh_buffer_from_file(session)
end

function M.on_transcript_updated(session, text, mode)
  session.view_state = session.view_state or {}
  if mode == "w" then
    session.view_state.force_full_refresh = true
    session.view_state.preserve_existing_transcript = nil
    session.view_state.pending_append = ""
    close_timer(session.view_state.append_timer)
    session.view_state.append_timer = nil
    refresh_buffer_from_file(session)
    return
  end
  if session.view_state.force_full_refresh then
    refresh_buffer_from_file(session)
    return
  end
  queue_append(session, text)
end

function M.configure_pane(pane_id, opts)
  local key = tostring(pane_id)
  local merged = vim.tbl_extend("force", pane_config[key] or {}, opts or {})
  local source_win = resolve_anchor_window(merged.source_winid)
  if source_win then
    merged.source_window_options = capture_window_options(source_win) or merged.source_window_options
  end
  pane_config[key] = merged
  if pane_config[key].follow_output == nil then
    pane_config[key].follow_output = true
  end
  return true
end

function M.clear_pane_config(pane_id)
  pane_config[tostring(pane_id)] = nil
  return true
end

function M.release_session_resources(session)
  if type(session) ~= "table" then
    return false
  end

  local bufnr = to_bufnr(session.pane_id)
  if bufnr then
    cleanup_markdown_rendering(bufnr)
  end

  local view_state = type(session.view_state) == "table" and session.view_state or nil
  local source_winid = view_state and view_state.source_winid or nil
  if view_state then
    close_timer(view_state.append_timer)
  end

  session.view_state = source_winid ~= nil and { source_winid = source_winid } or {}
  return true
end

function M.pane_exists(pane_id)
  return to_bufnr(pane_id) ~= nil or pane_config[tostring(pane_id)] ~= nil
end

function M.kill_pane(pane_id, session)
  local bufnr = to_bufnr(pane_id)
  if session then
    M.release_session_resources(session)
  end
  if bufnr then
    cleanup_markdown_rendering(bufnr)
  end
  pane_buffers[tostring(pane_id)] = nil
  pane_config[tostring(pane_id)] = nil
  if not bufnr then
    return true
  end
  close_buffer_windows(bufnr)
  layout_state[tostring(bufnr)] = nil
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  return true
end

function M.get_pane_info(pane_id, on_info)
  local bufnr = to_bufnr(pane_id)
  local info = nil
  if bufnr then
    local win = first_visible_window(bufnr)
    if win then
      info = {
        width = vim.api.nvim_win_get_width(win),
        height = vim.api.nvim_win_get_height(win),
      }
    end
  end
  if on_info then
    vim.schedule(function()
      on_info(info)
    end)
  end
  return info ~= nil
end

function M.break_pane(pane_id)
  local bufnr = to_bufnr(pane_id)
  if not bufnr then
    return pane_config[tostring(pane_id)] ~= nil
  end
  close_buffer_windows(bufnr)
  if should_release_buffer_on_hide(pane_id) then
    release_transcript_buffer(pane_id, bufnr)
  end
  return true
end

function M.break_pane_sync(pane_id)
  return M.break_pane(pane_id)
end

function M.join_pane(pane_id, size, is_vertical, on_done, session)
  ensure_layout_autocmds()
  local bufnr = to_bufnr(pane_id)
  local pane_opts = pane_config[tostring(pane_id)] or {}
  local anchor_win = resolve_anchor_window(pane_opts.source_winid)
  local existing = bufnr and first_visible_window(bufnr) or nil
  if existing then
    pane_config[tostring(pane_id)] = vim.tbl_extend("force", pane_opts, {
      source_winid = anchor_win,
      source_window_options = capture_window_options(anchor_win) or pane_opts.source_window_options,
      pane_size = size or pane_opts.pane_size,
      is_vertical = is_vertical == true,
      buffer_background = pane_opts.buffer_background or (session and session.buffer_background) or nil,
      buffer_inactive_background = pane_opts.buffer_inactive_background
        or (session and session.buffer_inactive_background)
        or nil,
      table_layout = pane_opts.table_layout or (session and session.table_layout) or "table",
      fancy_mode = pane_opts.fancy_mode == true or (session and session.fancy_mode == true),
      release_buffer_on_hide = resolve_release_buffer_on_hide(pane_opts, session),
      transcript_max_lines = pane_opts.transcript_max_lines or (session and session.transcript_max_lines) or nil,
      transcript_compaction = vim.deepcopy(
        pane_opts.transcript_compaction or (session and session.transcript_compaction) or {}
      ),
    })
    refresh_buffer_layout(bufnr, { force_footer = true })
    if on_done then
      vim.schedule(function()
        on_done(true)
      end)
    end
    return true
  end

  if not bufnr then
    if not session then
      if on_done then
        vim.schedule(function()
          on_done(false)
        end)
      end
      return false
    end
    bufnr = create_transcript_buffer(pane_id, session.agent_name, session.transcript_path)
  end

  if anchor_win then
    pcall(vim.api.nvim_set_current_win, anchor_win)
  end

  if is_vertical then
    vim.cmd("vsplit")
  else
    vim.cmd("split")
  end
  local win = vim.api.nvim_get_current_win()
  set_window_size(win, size, is_vertical)
  vim.api.nvim_win_set_buf(win, bufnr)
  pane_config[tostring(pane_id)] = vim.tbl_extend("force", pane_config[tostring(pane_id)] or {}, {
    source_winid = anchor_win,
    source_window_options = capture_window_options(anchor_win) or pane_opts.source_window_options,
    pane_size = size or pane_opts.pane_size,
    is_vertical = is_vertical == true,
    follow_output = pane_opts.follow_output ~= false,
    buffer_background = pane_opts.buffer_background or (session and session.buffer_background) or nil,
    buffer_inactive_background = pane_opts.buffer_inactive_background
      or (session and session.buffer_inactive_background)
      or nil,
    table_layout = pane_opts.table_layout or (session and session.table_layout) or "table",
    fancy_mode = pane_opts.fancy_mode == true or (session and session.fancy_mode == true),
    release_buffer_on_hide = resolve_release_buffer_on_hide(pane_opts, session),
    transcript_max_lines = pane_opts.transcript_max_lines or (session and session.transcript_max_lines) or nil,
    transcript_compaction = vim.deepcopy(
      pane_opts.transcript_compaction or (session and session.transcript_compaction) or {}
    ),
  })
  apply_transcript_window_opts(win, is_vertical, pane_config[tostring(pane_id)])
  refresh_buffer_from_path(bufnr, session and session.transcript_path or buffer_var(bufnr, "lazyagent_acp_transcript_path"))

  if anchor_win and anchor_win ~= win then
    pcall(vim.api.nvim_set_current_win, anchor_win)
  end

  if on_done then
    vim.schedule(function()
      on_done(true)
    end)
  end
  return true
end

function M.open_fullscreen_transcript(pane_id, session)
  session = type(session) == "table" and session or nil
  if not session or not session.transcript_path or session.transcript_path == "" then
    return false
  end

  local source_opts = pane_config[tostring(pane_id)] or {}
  local tab_opts = vim.tbl_extend("force", {}, source_opts, {
    source_winid = nil,
    source_window_options = nil,
    pane_size = nil,
    is_vertical = false,
    follow_output = false,
    fancy_mode = false,
    table_layout = "table",
    release_buffer_on_hide = false,
    transcript_max_lines = nil,
  })
  tab_opts.transcript_compaction = vim.tbl_deep_extend(
    "force",
    vim.deepcopy(source_opts.transcript_compaction or session.transcript_compaction or {}),
    { enabled = false }
  )

  next_pane_seq = next_pane_seq + 1
  local inspector_pane_id = string.format("buffer-acp-inspector-%d", next_pane_seq)

  vim.cmd("tabnew")
  local win = vim.api.nvim_get_current_win()
  local bufnr = create_transcript_buffer(inspector_pane_id, session.agent_name or "agent", session.transcript_path)
  pane_config[tostring(inspector_pane_id)] = tab_opts

  vim.api.nvim_win_set_buf(win, bufnr)
  apply_transcript_window_opts(win, false, tab_opts)
  refresh_buffer_from_path(bufnr, session.transcript_path, { force = true })
  set_follow_output(bufnr, false)

  vim.bo[bufnr].bufhidden = "wipe"
  vim.b[bufnr].lazyagent_acp_fullscreen_transcript = true

  vim.keymap.set("n", "q", function()
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_get_current_buf() == bufnr then
      vim.cmd("tabclose")
    end
  end, {
    buffer = bufnr,
    noremap = true,
    nowait = true,
    silent = true,
    desc = "LazyAgentACP: close fullscreen transcript",
  })

  return true
end

function M.copy_mode()
  return false
end

local function scroll_window_by_key(win, key)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end

  local moved = false
  pcall(vim.api.nvim_win_call, win, function()
    local before = vim.fn.winsaveview()
    local termcode = vim.api.nvim_replace_termcodes(key, true, false, true)
    vim.cmd.normal({ bang = true, args = { termcode } })
    local after = vim.fn.winsaveview()
    moved = before.topline ~= after.topline or before.lnum ~= after.lnum or before.topfill ~= after.topfill
  end)
  return moved
end

function M.scroll_up(pane_id)
  local bufnr = to_bufnr(pane_id)
  if not bufnr then
    return false
  end

  local scrolled = false
  set_follow_output(bufnr, false)
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if scroll_window_by_key(win, "<C-u>") then
      scrolled = true
    end
  end
  return scrolled
end

function M.scroll_down(pane_id)
  local bufnr = to_bufnr(pane_id)
  if not bufnr then
    return false
  end

  local scrolled = false
  set_follow_output(bufnr, false)
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if scroll_window_by_key(win, "<C-d>") then
      scrolled = true
    end
  end
  return scrolled
end

function M.resume_follow(pane_id)
  local bufnr = to_bufnr(pane_id)
  if not bufnr then
    return false
  end
  set_follow_output(bufnr, true)
  M.refresh_footer(bufnr)
  scroll_buffer_to_end(bufnr)
  return true
end

function M.cleanup_if_idle()
  local cleaned = false

  for pane_id, bufnr in pairs(pane_buffers) do
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      pane_buffers[pane_id] = nil
      pane_config[pane_id] = nil
      cleaned = true
    end
  end

  for key, _ in pairs(layout_state) do
    local bufnr = tonumber(key)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      layout_state[key] = nil
      cleaned = true
    end
  end

  for key, entry in pairs(dedicated_transcript_windows) do
    local bufnr = entry and entry.bufnr or nil
    local winid = entry and entry.winid or nil
    if (bufnr and not vim.api.nvim_buf_is_valid(bufnr)) or (winid and not vim.api.nvim_win_is_valid(winid)) then
      dedicated_transcript_windows[key] = nil
      redirecting_transcript_windows[key] = nil
      cleaned = true
    end
  end

  return cleaned
end

return M
