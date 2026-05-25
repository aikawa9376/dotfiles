local M = {}

function M.setup(deps)
  local normalize_text = deps.normalize_text
  local file_uri = deps.file_uri
  local summarize_conversation_text = deps.summarize_conversation_text
  local SWITCH_HISTORY_RECENT_ITEMS = deps.switch_history_recent_items or 14
  local SWITCH_HISTORY_ITEM_BODY_LIMIT = deps.switch_history_item_body_limit or 6000
  local SWITCH_HISTORY_TOOL_LIMIT = deps.switch_history_tool_limit or 6
  local SWITCH_HISTORY_TRANSCRIPT_BYTE_LIMIT = deps.switch_history_transcript_byte_limit or (128 * 1024)

  local module = {}

  local function read_body_ref(ref, fallback_path)
    if type(ref) ~= "table" then
      return ""
    end
    local path = ref.path or fallback_path
    if not path or path == "" or vim.fn.filereadable(path) ~= 1 then
      return ""
    end
    local start_line = math.max(1, tonumber(ref.start_line) or 1)
    local end_line = math.max(start_line, tonumber(ref.end_line) or start_line)
    local lines = {}
    if vim.fn.executable("sed") == 1 then
      local data = vim.fn.systemlist({ "sed", "-n", string.format("%d,%dp", start_line, end_line), path })
      if vim.v.shell_error == 0 and type(data) == "table" then
        lines = data
      end
    end
    if #lines == 0 then
      local ok, data = pcall(vim.fn.readfile, path, "", end_line)
      if ok and type(data) == "table" then
        lines = vim.list_slice(data, start_line, end_line)
      end
    end
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

  local function item_body(item, pending)
    if type(item) ~= "table" then
      return ""
    end
    if item.body and item.body ~= "" then
      return item.body
    end
    return read_body_ref(item.body_ref, pending and pending.transcript_path or nil)
  end

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

  local function switch_history_item_text(item, pending)
    if type(item) ~= "table" then
      return nil
    end

    local resolved_body = item_body(item, pending)
    local body = switch_history_body(resolved_body ~= "" and resolved_body or item.summary or item.title or "")
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
      local text = switch_history_item_text(item, pending)
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

  module.build_switch_history_blocks = build_switch_history_blocks

  return module
end

return M
