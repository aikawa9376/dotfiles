
local M = {}
local ContentBlocks = require("lazyagent.acp.content_blocks")

function M.setup(deps)
  local diff_utils = deps.diff_utils
  local normalize_text = deps.normalize_text
  local file_uri = deps.file_uri
  local write_session_transcript = deps.write_session_transcript
  local sync_runtime_live_state = deps.sync_runtime_live_state
  local section_icons = deps.section_icons or {}
  local summarize_conversation_text
  local heading_kind
  local tool_heading
  local append_block
  local build_switch_history_blocks
  local summarize_inline
  local resolve_permission_option

  local module = {}

local function section_kind(heading, meta)
  local explicit = type(meta) == "table" and tostring(meta.kind or ""):lower() or ""
  if explicit == "user" then
    return "User"
  end
  if explicit == "assistant" then
    return "Assistant"
  end
  if explicit == "thinking" then
    return "Thinking"
  end
  if explicit == "system" then
    return "System"
  end
  if explicit == "error" then
    return "Error"
  end
  if explicit == "plan" then
    return "Plan"
  end
  if explicit == "tool" then
    return "Tool"
  end
  if explicit == "terminal" then
    return "Terminal"
  end
  if explicit == "edited" then
    return "Edited"
  end
  return heading_kind(heading)
end

heading_kind = function(heading)
  heading = tostring(heading or "")
  if heading == "User" then
    return "User"
  end
  if heading == "Assistant" then
    return "Assistant"
  end
  if heading == "Thinking" then
    return "Thinking"
  end
  if heading == "System" then
    return "System"
  end
  if heading == "Error" then
    return "Error"
  end
  if heading == "Plan" then
    return "Plan"
  end
  if heading:match("^Tool") then
    return "Tool"
  end
  if heading:match("^Terminal") then
    return "Terminal"
  end
  if heading:match("^Edited ") then
    return "Edited"
  end
  return heading
end

local function section_icon_for_heading(heading, meta)
  local kind = section_kind(heading, meta)
  if kind == "Tool" then
    return "󱁤"
  end
  if kind == "Terminal" then
    return ""
  end
  if kind == "Edited" then
    return "󰏫"
  end
  return section_icons[kind] or "󰈔"
end

local function section_title(heading, meta)
  return section_icon_for_heading(heading, meta) .. " " .. tostring(heading or "")
end

local function section_width(heading, meta)
  local title = section_title(heading, meta)
  local ok, width = pcall(vim.fn.strdisplaywidth, title)
  width = ok and width or #title
  return math.max(44, width + 24)
end

local function section_has_tail(heading, meta)
  local kind = section_kind(heading, meta)
  return kind == "User" or kind == "Assistant"
end

local function render_section_header(heading, meta)
  local title = section_title(heading, meta)
  if not section_has_tail(heading, meta) then
    return "─ " .. title .. "\n"
  end
  local total = section_width(heading, meta)
  local title_width = vim.fn.strdisplaywidth(title)
  local tail = string.rep("─", math.max(8, total - title_width - 3))
  return "─ " .. title .. " " .. tail .. "\n"
end

local function pad_block_text(body)
  if body == "" then
    return ""
  end

  local padded = " " .. body
  padded = padded:gsub("\n([^\n])", "\n %1")
  return padded
end

local function pad_stream_chunk(body, at_line_start)
  if body == "" then
    return "", at_line_start
  end

  local padded = body
  if at_line_start then
    padded = " " .. padded
  end
  padded = padded:gsub("\n([^\n])", "\n %1")
  return padded, body:match("\n$") ~= nil
end

local function render_section_block(heading, body, meta)
  body = normalize_text(body)
  if body == "" then
    return ""
  end
  local lines = { render_section_header(heading, meta), pad_block_text(body) }
  if not body:match("\n$") then
    table.insert(lines, "\n")
  end
  return table.concat(lines)
end

summarize_conversation_text = function(text, limit)
  local normalized = normalize_text(text or "")
    :gsub("%s+", " ")
    :gsub("^%s+", "")
    :gsub("%s+$", "")
  limit = tonumber(limit) or 120
  if normalized == "" then
    return ""
  end
  if #normalized <= limit then
    return normalized
  end
  return normalized:sub(1, math.max(1, limit - 1)) .. "…"
end

local history = require("lazyagent.acp.backend.conversation.history").setup({
  normalize_text = normalize_text,
  file_uri = file_uri,
  summarize_conversation_text = summarize_conversation_text,
  switch_history_recent_items = deps.switch_history_recent_items,
  switch_history_item_body_limit = deps.switch_history_item_body_limit,
  switch_history_tool_limit = deps.switch_history_tool_limit,
  switch_history_transcript_byte_limit = deps.switch_history_transcript_byte_limit,
})
build_switch_history_blocks = history.build_switch_history_blocks

local function runtime_compaction_config(session)
  local cfg = type(session and session.runtime_compaction) == "table" and session.runtime_compaction or {}
  return {
    enabled = cfg.enabled ~= false,
    keep_recent_items = math.max(1, tonumber(cfg.keep_recent_items) or 80),
    keep_recent_tools = math.max(1, tonumber(cfg.keep_recent_tools) or 40),
    body_limit = math.max(256, tonumber(cfg.body_limit) or 12000),
    tool_output_limit = math.max(256, tonumber(cfg.tool_output_limit) or 24000),
  }
end

local function compact_old_text(text, limit)
  text = normalize_text(text or "")
  limit = tonumber(limit) or 0
  if text == "" or limit <= 0 or #text <= limit then
    return text
  end
  return text:sub(1, math.max(1, limit - 18)) .. "\n... [truncated]"
end

local function compact_tool_snapshot(tool)
  if type(tool) ~= "table" then
    return nil
  end
  return {
    toolCallId = tool.toolCallId,
    title = tool.title,
    kind = tool.kind,
    status = tool.status,
  }
end

local function safe_ref_component(value)
  local text = tostring(value or "item")
  text = text:gsub("[^%w_.-]+", "-")
  text = text:gsub("^-+", ""):gsub("-+$", "")
  return text ~= "" and text or "item"
end

local function count_newlines(text)
  local _, count = tostring(text or ""):gsub("\n", "")
  return count
end

local function transcript_position_after(count, trailing_newline, text)
  text = tostring(text or "")
  if text == "" then
    return tonumber(count) or 0, trailing_newline ~= false
  end

  count = tonumber(count) or 0
  local newline_count = count_newlines(text)
  local ends_newline = text:sub(-1) == "\n"
  local added
  if trailing_newline ~= false or count == 0 then
    added = newline_count + (ends_newline and 0 or 1)
  else
    added = newline_count
    if ends_newline then
      added = math.max(0, added - 1)
    end
  end
  return count + added, ends_newline
end

local function transcript_file_position(path)
  if not path or path == "" or vim.fn.filereadable(path) ~= 1 then
    return 0, true
  end

  if vim.fn.executable("wc") == 1 and vim.fn.executable("tail") == 1 then
    local lines = vim.fn.systemlist({ "wc", "-l", path })
    local count = type(lines) == "table" and tonumber(tostring(lines[1] or ""):match("^%s*(%d+)")) or nil
    if count then
      local last = vim.fn.system({ "tail", "-c", "1", path })
      local trailing = last == "\n" or last == ""
      if not trailing then
        count = count + 1
      end
      return count, trailing
    end
  end

  local ok, data = pcall(vim.fn.readfile, path)
  if not ok or type(data) ~= "table" then
    return 0, true
  end
  return #data, true
end

local function ensure_transcript_position(session)
  if not session then
    return 0, true
  end
  if session.transcript_line_count == nil or session._transcript_trailing_newline == nil then
    local count, trailing = transcript_file_position(session.transcript_path)
    session.transcript_line_count = count
    session._transcript_trailing_newline = trailing
  end
  return tonumber(session.transcript_line_count) or 0, session._transcript_trailing_newline ~= false
end

local function note_transcript_write(session, text)
  if not session then
    return
  end
  local count, trailing = ensure_transcript_position(session)
  local next_count, next_trailing = transcript_position_after(count, trailing, text)
  session.transcript_line_count = next_count
  session._transcript_trailing_newline = next_trailing
end

local function read_line_range(path, start_line, end_line)
  start_line = math.max(1, tonumber(start_line) or 1)
  end_line = math.max(start_line, tonumber(end_line) or start_line)
  if not path or path == "" or vim.fn.filereadable(path) ~= 1 then
    return {}
  end

  if vim.fn.executable("sed") == 1 then
    local data = vim.fn.systemlist({ "sed", "-n", string.format("%d,%dp", start_line, end_line), path })
    if vim.v.shell_error == 0 and type(data) == "table" then
      return data
    end
  end

  local ok, data = pcall(vim.fn.readfile, path, "", end_line)
  if not ok or type(data) ~= "table" then
    return {}
  end
  return vim.list_slice(data, start_line, end_line)
end

local function body_ref_text(ref)
  if type(ref) ~= "table" then
    return ""
  end
  local lines = read_line_range(ref.path, ref.start_line, ref.end_line)
  for idx, line in ipairs(lines) do
    line = tostring(line or "")
    if line:sub(1, 1) == " " then
      line = line:sub(2)
    end
    lines[idx] = line
  end
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end
  return normalize_text(table.concat(lines, "\n"))
end

local function item_body_text(item)
  if type(item) ~= "table" then
    return ""
  end
  if type(item.body_chunks) == "table" and #item.body_chunks > 0 then
    return normalize_text(table.concat(item.body_chunks))
  end
  if item.body and item.body ~= "" then
    return normalize_text(item.body)
  end
  return body_ref_text(item.body_ref)
end

local function can_reference_transcript(session)
  return type(session) == "table" and type(session.transcript_path) == "string" and session.transcript_path ~= ""
end

local function tool_ref_path(session, tool_call_id, kind)
  local transcript_path = session and session.transcript_path or nil
  if not transcript_path or transcript_path == "" then
    return nil
  end
  local dir = vim.fn.fnamemodify(transcript_path, ":h")
  local stem = vim.fn.fnamemodify(transcript_path, ":t:r")
  return string.format(
    "%s/%s-tool-%s-%s.log",
    dir,
    safe_ref_component(stem),
    safe_ref_component(tool_call_id),
    safe_ref_component(kind)
  )
end

local function write_text_ref(session, tool_call_id, kind, text)
  text = normalize_text(text or "")
  if text == "" then
    return nil
  end
  local path = tool_ref_path(session, tool_call_id, kind)
  if not path then
    return nil
  end
  local file = io.open(path, "w")
  if not file then
    return nil
  end
  file:write(text)
  file:close()
  return {
    path = path,
    bytes = #text,
  }
end

local function prune_runtime_timelines(session)
  if not session then
    return
  end
  local cfg = runtime_compaction_config(session)
  if not cfg.enabled then
    return
  end

  local conversation = session.conversation_timeline or {}
  local conversation_recent_start = math.max(1, #conversation - cfg.keep_recent_items + 1)
  for idx, item in ipairs(conversation) do
    if type(item) == "table" then
      if item.body_ref then
        item.body = ""
      elseif item.pinned == true or idx >= conversation_recent_start then
        item.body = compact_old_text(item.body, cfg.body_limit)
      else
        item.body = ""
        item.stream_key = nil
        item.compacted = true
      end
    end
  end

  local tools = session.tool_timeline or {}
  local tool_recent_start = math.max(1, #tools - cfg.keep_recent_tools + 1)
  for idx, entry in ipairs(tools) do
    if type(entry) == "table" then
      if entry.rendered_content_ref or entry.rendered_raw_output_ref then
        entry.rendered_content = ""
        entry.rendered_raw_output = ""
        entry.tool = compact_tool_snapshot(entry.tool)
      elseif entry.pinned == true or idx >= tool_recent_start then
        entry.rendered_content = compact_old_text(entry.rendered_content, cfg.tool_output_limit)
        entry.rendered_raw_output = compact_old_text(entry.rendered_raw_output, cfg.tool_output_limit)
        entry.tool = compact_tool_snapshot(entry.tool)
      else
        entry.rendered_content = ""
        entry.rendered_raw_output = ""
        entry.tool = nil
        entry.compacted = true
      end
    end
  end
end

local function conversation_kind_for_heading(heading)
  local kind = heading_kind(heading)
  if kind == "User" then
    return "user"
  end
  if kind == "Assistant" then
    return "assistant"
  end
  if kind == "Thinking" then
    return "thinking"
  end
  if kind == "System" then
    return "system"
  end
  if kind == "Error" then
    return "error"
  end
  if kind == "Plan" then
    return "plan"
  end
  if kind == "Tool" then
    return "tool"
  end
  if kind == "Terminal" then
    return "terminal"
  end
  if kind == "Edited" then
    return "edited"
  end
  return tostring(heading or ""):lower()
end

local function next_conversation_item_id(session)
  session.conversation_next_item_id = (tonumber(session.conversation_next_item_id) or 0) + 1
  return string.format("%s:%d", tostring(session.pane_id or session.agent_name or "acp"), session.conversation_next_item_id)
end

local function conversation_item_index(session, item_id)
  if not session or not item_id or type(session.conversation_timeline_index) ~= "table" then
    return nil
  end
  return session.conversation_timeline_index[item_id]
end

local function conversation_item_for_id(session, item_id)
  local idx = conversation_item_index(session, item_id)
  return idx and session.conversation_timeline and session.conversation_timeline[idx] or nil
end

local function sync_tool_pin_state(session, item)
  if not session or type(item) ~= "table" or not item.toolCallId then
    return
  end
  local idx = session.tool_timeline_index and session.tool_timeline_index[item.toolCallId] or nil
  local entry = idx and session.tool_timeline and session.tool_timeline[idx] or nil
  if not entry then
    return
  end
  if item.pinned == nil then
    item.pinned = entry.pinned == true
  else
    entry.pinned = item.pinned == true
  end
  entry.conversation_item_id = item.id
end

local function new_conversation_item(session, heading, body, meta)
  meta = type(meta) == "table" and meta or {}
  session.conversation_timeline = session.conversation_timeline or {}
  session.conversation_timeline_index = session.conversation_timeline_index or {}

  local body_chunks = type(meta.body_chunks) == "table" and meta.body_chunks or nil
  local body_ref = type(meta.body_ref) == "table" and meta.body_ref or nil
  local body_text = body or ""
  local item = {
    id = meta.id or next_conversation_item_id(session),
    seq = #session.conversation_timeline + 1,
    kind = meta.kind or conversation_kind_for_heading(heading),
    heading = heading,
    title = meta.title or heading,
    body = body_ref and "" or body_text,
    body_ref = body_ref,
    body_chunks = body_chunks,
    summary = meta.summary or summarize_conversation_text(body_text ~= "" and body_text or meta.title or heading, 140),
    pinned = meta.pinned == true,
    stream_key = meta.stream_key,
    toolCallId = meta.toolCallId,
    status = meta.status,
    path = meta.path,
  }
  if body_chunks then
    item._summary_source = tostring(body_text or ""):sub(1, 512)
  end

  session.conversation_timeline[#session.conversation_timeline + 1] = item
  session.conversation_timeline_index[item.id] = #session.conversation_timeline
  sync_tool_pin_state(session, item)
  return item
end

local function apply_conversation_item_meta(item, meta)
  if type(item) ~= "table" then
    return
  end
  meta = type(meta) == "table" and meta or {}
  if meta.title and meta.title ~= "" then
    item.title = meta.title
  end
  if meta.kind and meta.kind ~= "" then
    item.kind = meta.kind
  end
  if meta.toolCallId and meta.toolCallId ~= "" then
    item.toolCallId = meta.toolCallId
  end
  if meta.status and meta.status ~= "" then
    item.status = meta.status
  end
  if meta.path and meta.path ~= "" then
    item.path = meta.path
  end
  if meta.pinned ~= nil then
    item.pinned = meta.pinned == true
  end
end

local function update_conversation_item(item, body, meta)
  if type(item) ~= "table" then
    return
  end
  meta = type(meta) == "table" and meta or {}
  item.body = body or item.body or ""
  item.body_ref = type(meta.body_ref) == "table" and meta.body_ref or item.body_ref
  apply_conversation_item_meta(item, meta)
  local resolved_body = item_body_text(item)
  item.summary = meta.summary or summarize_conversation_text(resolved_body ~= "" and resolved_body or item.title or item.heading, 140)
end

local function append_conversation_item_chunk(item, chunk, meta)
  if type(item) ~= "table" then
    return
  end
  meta = type(meta) == "table" and meta or {}
  chunk = normalize_text(chunk or "")

  -- If we have a transcript reference, avoid keeping the full streamed body in
  -- memory (rendering/UI reads from the transcript file when needed).
  if chunk ~= "" and type(item.body_ref) ~= "table" then
    item.body_chunks = item.body_chunks or {}
    item.body_chunks[#item.body_chunks + 1] = chunk
    item.body = ""
  end

  apply_conversation_item_meta(item, meta)
  if meta.summary then
    item.summary = meta.summary
  else
    local summary_source = tostring(item._summary_source or "")
    if #summary_source < 512 and chunk ~= "" then
      item._summary_source = (summary_source .. chunk):sub(1, 512)
    end
    local source = tostring(item._summary_source or "")
    item.summary = summarize_conversation_text(source ~= "" and source or item.title or item.heading, 140)
  end
end

local function close_stream(session)
  if session.current_stream_key then
    if not session.current_stream_at_line_start then
      write_session_transcript(session, "\n")
      note_transcript_write(session, "\n")
    end
    local item = conversation_item_for_id(session, session.current_stream_item_id)
    if item and type(item.body_ref) == "table" then
      item.body_ref.end_line = session.transcript_line_count
      item.body_chunks = nil
      item.body = ""
      item._summary_source = nil
    elseif item and type(item.body_chunks) == "table" then
      item.body = table.concat(item.body_chunks)
      item.body_chunks = nil
      item._summary_source = nil
    end
    session.current_stream_key = nil
    session.current_stream_heading = nil
    session.current_stream_at_line_start = nil
    session.current_stream_item_id = nil
    session.transcript_has_content = true
  end
end

append_block = function(session, heading, body, meta)
  body = normalize_text(body)
  if body == "" then return end
  close_stream(session)
  local prefix = session.transcript_has_content and "\n" or ""
  ensure_transcript_position(session)
  local header = prefix .. render_section_header(heading, meta)
  local block_body = pad_block_text(body)
  if not body:match("\n$") then
    block_body = block_body .. "\n"
  end
  local header_count = transcript_position_after(
    session.transcript_line_count,
    session._transcript_trailing_newline,
    header
  )
  local rendered = header .. block_body
  local final_count = transcript_position_after(
    session.transcript_line_count,
    session._transcript_trailing_newline,
    rendered
  )
  local item_meta = meta or {}
  if can_reference_transcript(session) then
    item_meta = vim.tbl_extend("force", item_meta, {
      body_ref = {
        path = session.transcript_path,
        start_line = header_count + 1,
        end_line = final_count,
      },
    })
  end
  write_session_transcript(session, rendered)
  note_transcript_write(session, rendered)
  session.transcript_has_content = true
  new_conversation_item(session, heading, body, item_meta)
  prune_runtime_timelines(session)
  if sync_runtime_live_state then
    sync_runtime_live_state(session)
  end
end

local function append_stream_chunk(session, stream_key, heading, body, meta)
  body = normalize_text(body)
  if body == "" then return end
  if session.current_stream_key ~= stream_key then
    close_stream(session)
    local prefix = session.transcript_has_content and "\n" or ""
    ensure_transcript_position(session)
    local header = prefix .. render_section_header(heading, meta)
    local header_count = transcript_position_after(
      session.transcript_line_count,
      session._transcript_trailing_newline,
      header
    )
    write_session_transcript(session, header)
    note_transcript_write(session, header)
    session.current_stream_key = stream_key
    session.current_stream_heading = heading
    session.current_stream_at_line_start = true
    local item_meta = vim.tbl_extend("force", meta or {}, {
      stream_key = stream_key,
    })
    if can_reference_transcript(session) then
      item_meta.body_ref = {
        path = session.transcript_path,
        start_line = header_count + 1,
        end_line = header_count,
      }
    else
      item_meta.body_chunks = { body }
    end
    local item = new_conversation_item(session, heading, body, item_meta)
    session.current_stream_item_id = item.id
    session.transcript_has_content = true
  else
    local item = conversation_item_for_id(session, session.current_stream_item_id)
    if item then
      append_conversation_item_chunk(item, body, meta)
      sync_tool_pin_state(session, item)
    end
  end
  prune_runtime_timelines(session)
  local padded, next_at_line_start = pad_stream_chunk(body, session.current_stream_at_line_start)
  write_session_transcript(session, padded)
  note_transcript_write(session, padded)
  local item = conversation_item_for_id(session, session.current_stream_item_id)
  if item and type(item.body_ref) == "table" then
    item.body_ref.end_line = session.transcript_line_count
  end
  session.current_stream_at_line_start = next_at_line_start
  if sync_runtime_live_state then
    sync_runtime_live_state(session)
  end
end

local function render_content(content)
  return ContentBlocks.render(content)
end

local function render_tool_content(content)
  if type(content) ~= "table" then return "" end
  local parts = {}
  for _, item in ipairs(content) do
    if type(item) == "table" then
      if item.type == "content" and item.content then
        local text = render_content(item.content)
        if text ~= "" then table.insert(parts, text) end
      elseif item.type == "diff" then
        table.insert(parts, table.concat(diff_utils.format_diff_item(item), "\n"))
      elseif item.type == "terminal" then
        table.insert(parts, "[terminal " .. tostring(item.terminalId or "") .. "]")
      end
    end
  end
  return table.concat(parts, "\n")
end

local function render_tool_raw_output(raw_output)
  if type(raw_output) == "string" then
    return raw_output
  end
  if type(raw_output) ~= "table" then
    return ""
  end

  local parts = {}
  if raw_output.message and raw_output.message ~= "" then
    table.insert(parts, tostring(raw_output.message))
  end
  if raw_output.code and raw_output.code ~= "" then
    table.insert(parts, "[code] " .. tostring(raw_output.code))
  end
  if raw_output.content and raw_output.content ~= "" then
    table.insert(parts, tostring(raw_output.content))
  end
  if raw_output.detailedContent and raw_output.detailedContent ~= "" and raw_output.detailedContent ~= raw_output.content then
    table.insert(parts, tostring(raw_output.detailedContent))
  end
  return table.concat(parts, "\n")
end

local function summarize_tool_block(tool, title, body)
  title = tostring(title or "tool")
  body = normalize_text(body or "")
  if body == "" then
    return title
  end

  local action = tostring(tool and tool.kind or ""):lower()
  local status = tostring(tool and tool.status or ""):lower()
  if action == "edit" and status == "pending" then
    return title
  end
  if action == "edit" and (
    status == "failed"
    or status == "error"
    or status == "errored"
    or status == "cancelled"
    or status == "canceled"
    or status == "rejected"
  ) then
    return string.format("%s\n%s", title, summarize_inline(body, 140))
  end
  if action == "edit" then
    return title .. "\n" .. body
  end

  local lines = vim.split(body, "\n", { plain = true })
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines, #lines)
  end
  local count = #lines
  if count <= 0 then
    return title
  end

  local unit = count == 1 and "line" or "lines"
  return string.format("%s\n%s %d %s", title, action ~= "" and action or "tool", count, unit)
end

summarize_inline = function(text, limit)
  local normalized = normalize_text(text or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  limit = tonumber(limit) or 120
  if normalized == "" then
    return ""
  end
  if #normalized <= limit then
    return normalized
  end
  return normalized:sub(1, math.max(1, limit - 1)) .. "…"
end

local function to_match_values(value)
  if value == nil then
    return {}
  end
  if type(value) == "table" then
    local out = {}
    for _, item in ipairs(value) do
      if item ~= nil and tostring(item) ~= "" then
        out[#out + 1] = tostring(item)
      end
    end
    return out
  end
  local text = tostring(value)
  if text == "" then
    return {}
  end
  return { text }
end

local function matches_exact(candidates, expected)
  local values = to_match_values(expected)
  if #values == 0 then
    return true
  end
  for _, wanted in ipairs(values) do
    local needle = wanted:lower()
    for _, candidate in ipairs(candidates or {}) do
      if tostring(candidate or ""):lower() == needle then
        return true
      end
    end
  end
  return false
end

local function matches_pattern(candidates, expected)
  local values = to_match_values(expected)
  if #values == 0 then
    return true
  end
  for _, pattern in ipairs(values) do
    for _, candidate in ipairs(candidates or {}) do
      local ok, matched = pcall(string.match, tostring(candidate or ""), pattern)
      if ok and matched then
        return true
      end
    end
  end
  return false
end

local function add_unique_text(list, seen, value)
  local text = tostring(value or "")
  if text == "" or seen[text] then
    return
  end
  seen[text] = true
  list[#list + 1] = text
end

local function maybe_add_uri_path(list, seen, uri)
  local text = tostring(uri or "")
  if text == "" then
    return
  end
  if text:match("^file://") then
    local ok, path = pcall(vim.uri_to_fname, text)
    if ok and path and path ~= "" then
      add_unique_text(list, seen, path)
      return
    end
  end
  add_unique_text(list, seen, text)
end

local function normalize_tool_path(path, cwd)
  local text = tostring(path or "")
  if text == "" then
    return nil
  end

  if text:match("^file://") then
    local ok, resolved = pcall(vim.uri_to_fname, text)
    if ok and resolved and resolved ~= "" then
      text = resolved
    end
  elseif not text:match("^/") then
    text = (cwd or vim.fn.getcwd()) .. "/" .. text
  end

  local normalized = vim.fn.fnamemodify(text, ":p")
  if vim.fs and type(vim.fs.normalize) == "function" then
    normalized = vim.fs.normalize(normalized)
  end
  return normalized
end

local function extract_tool_paths(tool)
  local out = {}
  local seen = {}
  if type(tool) ~= "table" then
    return out
  end

  add_unique_text(out, seen, tool.path)
  if type(tool.paths) == "table" then
    for _, path in ipairs(tool.paths) do
      add_unique_text(out, seen, path)
    end
  end

  for _, item in ipairs(tool.content or {}) do
    if type(item) == "table" then
      if item.type == "diff" then
        add_unique_text(out, seen, item.path)
      elseif item.type == "content" and type(item.content) == "table" then
        local content = item.content
        maybe_add_uri_path(out, seen, content.uri)
        if type(content.resource) == "table" then
          maybe_add_uri_path(out, seen, content.resource.uri)
        end
      end
    end
  end

  if type(tool.rawOutput) == "table" then
    add_unique_text(out, seen, tool.rawOutput.path)
    add_unique_text(out, seen, tool.rawOutput.file)
  end

  return out
end

local function tool_match_fields(tool)
  local fields = {
    title = {},
    tool = {},
    kind = {},
    path = extract_tool_paths(tool),
    text = {},
    agent = {},
    cwd = {},
  }

  add_unique_text(fields.title, {}, tool and tool.title)
  local tool_seen = {}
  add_unique_text(fields.tool, tool_seen, tool and tool.name)
  add_unique_text(fields.tool, tool_seen, tool and tool.toolName)
  add_unique_text(fields.tool, tool_seen, tool and tool.title)
  add_unique_text(fields.tool, tool_seen, tool and tool.toolCallId)
  add_unique_text(fields.kind, {}, tool and tool.kind)

  local text_seen = {}
  add_unique_text(fields.text, text_seen, tool and tool.title)
  add_unique_text(fields.text, text_seen, render_tool_content(tool and tool.content))
  add_unique_text(fields.text, text_seen, render_tool_raw_output(tool and tool.rawOutput))

  return fields
end

local function permission_rule_label(rule, idx)
  if type(rule) ~= "table" then
    return string.format("rule #%d", idx)
  end
  local label = rule.name or rule.label or rule.id
  if label and tostring(label) ~= "" then
    return tostring(label)
  end
  return string.format("rule #%d", idx)
end

resolve_permission_option = function(options, preferred_kind)
  if type(options) ~= "table" then
    return nil
  end
  if preferred_kind then
    for _, option in ipairs(options) do
      if option.kind == preferred_kind then
        return option
      end
    end
  end
  if preferred_kind and preferred_kind:match("^allow") then
    for _, option in ipairs(options) do
      if type(option.kind) == "string" and option.kind:match("^allow") then
        return option
      end
    end
  end
  if preferred_kind and preferred_kind:match("^reject") then
    for _, option in ipairs(options) do
      if type(option.kind) == "string" and option.kind:match("^reject") then
        return option
      end
    end
  end
  return options[1]
end

local function resolve_permission_rule_action(options, action)
  local normalized = tostring(action or ""):lower()
  if normalized == "" or normalized == "prompt" or normalized == "manual" or normalized == "ask" then
    return nil
  end
  return resolve_permission_option(options, normalized)
end

local function permission_rule_matches(session, rule, tool)
  if type(rule) ~= "table" then
    return false
  end

  local fields = tool_match_fields(tool)
  fields.agent = { tostring(session and session.agent_name or "") }
  fields.cwd = {
    tostring(session and session.cwd or ""),
    tostring(session and session.root_dir or ""),
  }

  if not matches_exact(fields.agent, rule.agent) then
    return false
  end
  if not matches_pattern(fields.agent, rule.agent_pattern) then
    return false
  end
  if not matches_exact(fields.cwd, rule.cwd) then
    return false
  end
  if not matches_pattern(fields.cwd, rule.cwd_pattern) then
    return false
  end
  if not matches_exact(fields.tool, rule.tool) then
    return false
  end
  if not matches_pattern(fields.tool, rule.tool_pattern) then
    return false
  end
  if not matches_exact(fields.title, rule.title) then
    return false
  end
  if not matches_pattern(fields.title, rule.title_pattern) then
    return false
  end
  if not matches_exact(fields.kind, rule.kind) then
    return false
  end
  if not matches_pattern(fields.kind, rule.kind_pattern) then
    return false
  end
  if not matches_exact(fields.path, rule.path) then
    return false
  end
  if not matches_pattern(fields.path, rule.path_pattern) then
    return false
  end
  if not matches_pattern(fields.text, rule.text_pattern) then
    return false
  end

  return true
end

local function resolve_permission_rule(session, tool, options)
  local rules = type(session and session.permission_rules) == "table" and session.permission_rules or {}
  for idx, rule in ipairs(rules) do
    if permission_rule_matches(session, rule, tool) then
      local action = tostring(rule.action or rule.outcome or "")
      return {
        matched = true,
        label = permission_rule_label(rule, idx),
        action = action,
        option = resolve_permission_rule_action(options, action),
      }
    end
  end
  return { matched = false }
end

local function summarize_tool(tool)
  if type(tool) ~= "table" then
    return ""
  end
  local paths = extract_tool_paths(tool)
  if type(tool.content) == "table" then
    for _, item in ipairs(tool.content) do
      if type(item) == "table" and item.type == "diff" then
        local target = paths[1] or item.path or tool.title or tool.toolCallId or "diff"
        if #paths > 1 then
          return string.format("%s (+%d more)", target, #paths - 1)
        end
        return tostring(target)
      end
    end
  end
  local body = render_tool_content(tool.content)
  if body == "" then
    body = render_tool_raw_output(tool.rawOutput)
  end
  if body ~= "" then
    return summarize_inline(body, 140)
  end
  return summarize_inline(tool.title or tool.toolCallId or "tool", 140)
end

local function upsert_tool_timeline(session, tool)
  if not session or type(tool) ~= "table" or not tool.toolCallId then
    return
  end

  session.tool_timeline = session.tool_timeline or {}
  session.tool_timeline_index = session.tool_timeline_index or {}
  local idx = session.tool_timeline_index[tool.toolCallId]
  local entry = idx and session.tool_timeline[idx] or {
    seq = #session.tool_timeline + 1,
    toolCallId = tool.toolCallId,
  }

  entry.title = tool.title or entry.title or tool.toolCallId
  entry.heading = tool_heading(tool)
  entry.status = tool.status or entry.status
  entry.kind = tool.kind or entry.kind
  entry.paths = extract_tool_paths(tool)
  entry.summary = summarize_tool(tool)
  local rendered_content = render_tool_content(tool.content)
  local rendered_raw_output = render_tool_raw_output(tool.rawOutput)
  entry.rendered_content_ref = write_text_ref(session, tool.toolCallId, "content", rendered_content)
  entry.rendered_raw_output_ref = write_text_ref(session, tool.toolCallId, "raw", rendered_raw_output)
  entry.rendered_content = entry.rendered_content_ref and "" or rendered_content
  entry.rendered_raw_output = entry.rendered_raw_output_ref and "" or rendered_raw_output
  entry.pinned = entry.pinned == true
  entry.tool = compact_tool_snapshot(tool)

  if not idx then
    session.tool_timeline[#session.tool_timeline + 1] = entry
    session.tool_timeline_index[tool.toolCallId] = #session.tool_timeline
  else
    session.tool_timeline[idx] = entry
  end
  prune_runtime_timelines(session)
  if sync_runtime_live_state then
    sync_runtime_live_state(session)
  end
end

local function tool_timeline_entry_for_call(session, tool_call_id)
  if not session or not tool_call_id or tool_call_id == "" then
    return nil
  end

  local idx = session.tool_timeline_index and session.tool_timeline_index[tool_call_id] or nil
  local entry = idx and session.tool_timeline and session.tool_timeline[idx] or nil
  if entry then
    return entry
  end

  for seq, item in ipairs(session.tool_timeline or {}) do
    if type(item) == "table" and item.toolCallId == tool_call_id then
      session.tool_timeline_index = session.tool_timeline_index or {}
      session.tool_timeline_index[tool_call_id] = seq
      return item
    end
  end

  return nil
end

local function merge_tool_update(session, update)
  local tool_id = update.toolCallId or ("tool-" .. tostring(#session.tool_calls + 1))
  local merged = vim.tbl_deep_extend("force", session.tool_calls[tool_id] or {}, update)
  merged.toolCallId = tool_id
  session.tool_calls[tool_id] = merged
  upsert_tool_timeline(session, merged)
  return merged
end

local function tool_update_is_terminal(tool)
  local status = tostring(tool and tool.status or ""):lower()
  return status == "completed"
    or status == "complete"
    or status == "finished"
    or status == "done"
    or status == "failed"
    or status == "error"
    or status == "errored"
    or status == "cancelled"
    or status == "canceled"
    or status == "rejected"
end

  tool_heading = function(tool)
    local parts = { "Tool" }
    if tool.kind and tool.kind ~= "" then
      table.insert(parts, tool.kind)
    end
    if tool.status and tool.status ~= "" then
      table.insert(parts, tool.status)
    end
    return table.concat(parts, " ")
  end

  module.build_switch_history_blocks = build_switch_history_blocks
  module.render_section_block = render_section_block
  module.summarize_conversation_text = summarize_conversation_text
  module.item_body_text = item_body_text
  module.new_conversation_item = new_conversation_item
  module.conversation_item_for_id = conversation_item_for_id
  module.sync_tool_pin_state = sync_tool_pin_state
  module.close_stream = close_stream
  module.append_block = append_block
  module.append_stream_chunk = append_stream_chunk
  module.render_content = render_content
  module.render_tool_content = render_tool_content
  module.render_tool_raw_output = render_tool_raw_output
  module.summarize_tool_block = summarize_tool_block
  module.summarize_tool = summarize_tool
  module.matches_exact = matches_exact
  module.matches_pattern = matches_pattern
  module.normalize_tool_path = normalize_tool_path
  module.extract_tool_paths = extract_tool_paths
  module.resolve_permission_rule = resolve_permission_rule
  module.upsert_tool_timeline = upsert_tool_timeline
  module.tool_timeline_entry_for_call = tool_timeline_entry_for_call
  module.merge_tool_update = merge_tool_update
  module.tool_update_is_terminal = tool_update_is_terminal
  module.tool_heading = tool_heading

  return module
end

return M
