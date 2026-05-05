
local M = {}

function M.setup(deps)
  local diff_utils = deps.diff_utils
  local normalize_text = deps.normalize_text
  local file_uri = deps.file_uri
  local write_session_transcript = deps.write_session_transcript
  local sync_runtime_live_state = deps.sync_runtime_live_state
  local section_icons = deps.section_icons or {}
  local SWITCH_HISTORY_RECENT_ITEMS = deps.switch_history_recent_items or 14
  local SWITCH_HISTORY_ITEM_BODY_LIMIT = deps.switch_history_item_body_limit or 6000
  local SWITCH_HISTORY_TOOL_LIMIT = deps.switch_history_tool_limit or 6
  local SWITCH_HISTORY_TRANSCRIPT_BYTE_LIMIT = deps.switch_history_transcript_byte_limit or (128 * 1024)
  local summarize_conversation_text
  local heading_kind
  local tool_heading
  local append_block

  local module = {}

local function switch_history_label(item)
  local kind = tostring(item and (item.kind or item.heading) or ""):lower()
  if kind == "user" then
    return "User"
  elseif kind == "assistant" then
    return "Assistant"
  elseif kind == "thinking" then
    return "Assistant (thinking)"
  elseif kind == "plan" then
    return "Plan"
  elseif kind == "tool" then
    return "Tool"
  elseif kind == "terminal" then
    return "Terminal"
  elseif kind == "edited" then
    return "Edited"
  elseif kind == "error" then
    return "Error"
  end
  return item and item.heading or "Context"
end

local function switch_history_body(text)
  text = normalize_text(text or "")
  if text == "" then
    return ""
  end
  if #text <= SWITCH_HISTORY_ITEM_BODY_LIMIT then
    return text
  end
  return text:sub(1, SWITCH_HISTORY_ITEM_BODY_LIMIT) .. "\n... [truncated]"
end

local function switch_history_item_text(item)
  if type(item) ~= "table" then
    return nil
  end

  local body = switch_history_body(item.body ~= "" and item.body or item.summary or item.title or "")
  if body == "" then
    return nil
  end

  local label = switch_history_label(item)
  local title = tostring(item.title or "")
  local status = tostring(item.status or "")

  if label == "User" or label == "Assistant" or label == "Assistant (thinking)" then
    local speaker = label == "Assistant" and tostring(item.heading or item.title or label) or label
    return string.format("%s: %s", speaker, body)
  end

  local header = label
  if title ~= "" and title ~= item.heading and title ~= label then
    header = header .. " - " .. title
  end
  if status ~= "" then
    header = header .. " [" .. status .. "]"
  end

  return header .. ":\n" .. body
end

local function include_switch_history_item(item)
  if type(item) ~= "table" then
    return false
  end
  local kind = tostring(item.kind or ""):lower()
  if kind == "system" or kind == "" then
    return false
  end
  local body = tostring(item.body or item.summary or "")
  if kind == "error" then
    return true
  end
  if body:match("^Connecting ACP session") or body:match("^ACP session ready:") or body:match("^Switched ACP provider") then
    return false
  end
  return true
end

local function collect_switch_history_items(pending)
  local source = {}
  for _, item in ipairs(pending and pending.conversation_timeline or {}) do
    if include_switch_history_item(item) then
      source[#source + 1] = item
    end
  end

  if #source <= SWITCH_HISTORY_RECENT_ITEMS then
    return source
  end

  local keep = {}
  local recent_start = math.max(1, #source - SWITCH_HISTORY_RECENT_ITEMS + 1)
  for idx, item in ipairs(source) do
    if item.pinned == true or idx >= recent_start then
      keep[#keep + 1] = item
    end
  end
  return keep
end

local function recent_switch_tool_lines(pending)
  local tools = pending and pending.tool_timeline or {}
  if type(tools) ~= "table" or #tools == 0 then
    return nil
  end

  local lines = { "Recent tool activity:" }
  local start = math.max(1, #tools - SWITCH_HISTORY_TOOL_LIMIT + 1)
  for idx = start, #tools do
    local tool = tools[idx]
    if type(tool) == "table" then
      local status = tool.status and tool.status ~= "" and (" [" .. tostring(tool.status) .. "]") or ""
      local summary = summarize_conversation_text(tool.summary or tool.title or tool.toolCallId or "tool", 280)
      lines[#lines + 1] = string.format("- %s%s", summary, status)
    end
  end

  return #lines > 1 and table.concat(lines, "\n") or nil
end

local function build_switch_history_blocks(session, pending)
  if type(pending) ~= "table" then
    return {}
  end

  local blocks = {}
  local carryover_label = pending.carryover_label
  if not carryover_label or carryover_label == "" then
    carryover_label = "the previous ACP provider"
    if pending.provider_from and pending.provider_from ~= "" then
      carryover_label = string.format("%s (%s)", carryover_label, tostring(pending.provider_from))
    end
  end
  local history_items = collect_switch_history_items(pending)
  local intro = {
    string.format("Conversation carryover from %s.", carryover_label),
    "Treat the following as existing conversation history for this session.",
    "Do not ask me to restate it. Respond only to the new user message that follows.",
  }
  blocks[#blocks + 1] = {
    type = "text",
    text = table.concat(intro, "\n"),
  }

  for _, item in ipairs(history_items) do
    local text = switch_history_item_text(item)
    if text and text ~= "" then
      blocks[#blocks + 1] = {
        type = "text",
        text = text,
      }
    end
  end

  local has_detailed_tool_history = false
  for _, item in ipairs(history_items) do
    local kind = tostring(item.kind or ""):lower()
    if kind == "tool" or kind == "terminal" or kind == "edited" then
      has_detailed_tool_history = true
      break
    end
  end

  local tool_lines = recent_switch_tool_lines(pending)
  if tool_lines and not has_detailed_tool_history then
    blocks[#blocks + 1] = {
      type = "text",
      text = tool_lines,
    }
  end

  if pending.transcript_path and pending.transcript_path ~= "" then
    if session.prompt_supports_embedded_context == true then
      local transcript_text = table.concat(pending.transcript_lines or {}, "\n")
      if #transcript_text > SWITCH_HISTORY_TRANSCRIPT_BYTE_LIMIT then
        transcript_text = transcript_text:sub(1, SWITCH_HISTORY_TRANSCRIPT_BYTE_LIMIT) .. "\n... [truncated]"
      end
      blocks[#blocks + 1] = {
        type = "resource",
        resource = {
          uri = file_uri(pending.transcript_path),
          mimeType = "text/plain",
          text = transcript_text,
        },
      }
    else
      blocks[#blocks + 1] = {
        type = "resource_link",
        uri = file_uri(pending.transcript_path),
        name = vim.fn.fnamemodify(pending.transcript_path, ":t"),
        title = "Previous conversation transcript",
        mimeType = "text/plain",
      }
    end
  end

  return blocks
end

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

  local item = {
    id = meta.id or next_conversation_item_id(session),
    seq = #session.conversation_timeline + 1,
    kind = meta.kind or conversation_kind_for_heading(heading),
    heading = heading,
    title = meta.title or heading,
    body = body or "",
    summary = meta.summary or summarize_conversation_text(body or meta.title or heading, 140),
    pinned = meta.pinned == true,
    stream_key = meta.stream_key,
    toolCallId = meta.toolCallId,
    status = meta.status,
    path = meta.path,
  }

  session.conversation_timeline[#session.conversation_timeline + 1] = item
  session.conversation_timeline_index[item.id] = #session.conversation_timeline
  sync_tool_pin_state(session, item)
  return item
end

local function update_conversation_item(item, body, meta)
  if type(item) ~= "table" then
    return
  end
  meta = type(meta) == "table" and meta or {}
  item.body = body or item.body or ""
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
  item.summary = meta.summary or summarize_conversation_text(item.body ~= "" and item.body or item.title or item.heading, 140)
end

local function close_stream(session)
  if session.current_stream_key then
    if not session.current_stream_at_line_start then
      write_session_transcript(session, "\n")
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
  write_session_transcript(session, prefix .. render_section_block(heading, body, meta))
  session.transcript_has_content = true
  new_conversation_item(session, heading, body, meta)
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
    write_session_transcript(session, prefix .. render_section_header(heading, meta))
    session.current_stream_key = stream_key
    session.current_stream_heading = heading
    session.current_stream_at_line_start = true
    local item = new_conversation_item(session, heading, body, vim.tbl_extend("force", meta or {}, {
      stream_key = stream_key,
    }))
    session.current_stream_item_id = item.id
    session.transcript_has_content = true
  else
    local item = conversation_item_for_id(session, session.current_stream_item_id)
    if item then
      update_conversation_item(item, (item.body or "") .. body, meta)
      sync_tool_pin_state(session, item)
    end
  end
  local padded, next_at_line_start = pad_stream_chunk(body, session.current_stream_at_line_start)
  write_session_transcript(session, padded)
  session.current_stream_at_line_start = next_at_line_start
  if sync_runtime_live_state then
    sync_runtime_live_state(session)
  end
end

local function render_content(content)
  if type(content) ~= "table" then
    return tostring(content or "")
  end

  if content.type == "text" then
    return content.text or ""
  end

  if content.type == "resource_link" then
    return table.concat(vim.tbl_filter(function(item) return item and item ~= "" end, {
      content.name,
      content.uri,
    }), " - ")
  end

  if content.type == "resource" and type(content.resource) == "table" then
    return content.resource.text or content.resource.uri or ""
  end

  if content.type == "image" then
    return "[image] " .. (content.uri or content.mimeType or "image")
  end

  if content.type == "audio" then
    return "[audio] " .. (content.mimeType or "audio")
  end

  return vim.inspect(content)
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

local function summarize_inline(text, limit)
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
  entry.rendered_content = render_tool_content(tool.content)
  entry.rendered_raw_output = render_tool_raw_output(tool.rawOutput)
  entry.pinned = entry.pinned == true
  entry.tool = vim.deepcopy(tool)

  if not idx then
    session.tool_timeline[#session.tool_timeline + 1] = entry
    session.tool_timeline_index[tool.toolCallId] = #session.tool_timeline
  else
    session.tool_timeline[idx] = entry
  end
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
