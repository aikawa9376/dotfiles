local M = {}

local cache_logic = require("lazyagent.logic.cache")
local ACPClient = require("lazyagent.acp.client")
local local_commands = require("lazyagent.acp.local_commands")
local agent_logic = require("lazyagent.logic.agent")
local acp_logic = require("lazyagent.logic.acp")
local diff_utils = require("lazyagent.acp.diff")
local summary_logic = require("lazyagent.logic.summary")
local transforms = require("lazyagent.transforms")
local util = require("lazyagent.util")
local state = require("lazyagent.logic.state")

local sessions = {}
local terminal_seq = 0
local section_icons = {
  User = "󰍩",
  Assistant = "󰭹",
  Thinking = "󰔟",
  System = "󰋽",
  Error = "󰅚",
  Plan = "󰐕",
}
local SWITCH_HISTORY_RECENT_ITEMS = 14
local SWITCH_HISTORY_ITEM_BODY_LIMIT = 6000
local SWITCH_HISTORY_TOOL_LIMIT = 6
local SWITCH_HISTORY_TRANSCRIPT_BYTE_LIMIT = 128 * 1024
local summarize_conversation_text
local resolve_permission_option
local tool_heading
local buffer_root_for_session
local sync_runtime_session
local sync_runtime_live_state
local clear_pending_switch_history
local append_block
local heading_kind

local sanitize_filename_component = util.sanitize_filename_component

local function transcript_dir()
  local dir = cache_logic.get_cache_dir() .. "/acp"
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
  return dir
end

local function build_transcript_path(agent_name, source_bufnr)
  local instance_id = tostring(vim.fn.getpid())
  return table.concat({
    transcript_dir(),
    "/",
    cache_logic.build_cache_prefix(source_bufnr),
    instance_id,
    "-",
    sanitize_filename_component(agent_name),
    "-live.log",
  })
end

local function get_session(pane_id)
  return sessions[pane_id]
end

local function normalize_text(text)
  return util.normalize_text(text, { ensure_trailing_newline = false })
end

local function file_uri(path)
  return vim.uri_from_fname(path)
end

local function read_buffer_lines_for_path(path)
  local normalized = vim.fn.fnamemodify(path, ":p")
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "" and vim.fn.fnamemodify(name, ":p") == normalized then
        return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), bufnr
      end
    end
  end
  return nil, nil
end

local function read_path_lines(path)
  local lines, bufnr = read_buffer_lines_for_path(path)
  if lines then
    return lines, bufnr
  end
  if vim.fn.filereadable(path) == 1 then
    local ok, data = pcall(vim.fn.readfile, path)
    if ok and data then
      return data, nil
    end
  end
  return nil, nil
end

local function clamp_utf8_from_end(text, byte_limit)
  if not byte_limit or byte_limit <= 0 or #text <= byte_limit then
    return text, false
  end

  local start = #text - byte_limit + 1
  while start <= #text do
    local byte = string.byte(text, start)
    if not byte or byte < 128 or byte >= 192 then
      break
    end
    start = start + 1
  end
  return text:sub(start), true
end

local function ensure_parent_dir(path)
  local dir = vim.fn.fnamemodify(path, ":h")
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
end

local function write_transcript(path, text, mode)
  ensure_parent_dir(path)
  local file = io.open(path, mode or "a")
  if not file then return false end
  file:write(text)
  file:close()
  return true
end

local function write_session_transcript(session, text, mode)
  local ok = write_transcript(session.transcript_path, text, mode)
  if ok and session.view and type(session.view.on_transcript_updated) == "function" then
    vim.schedule(function()
      pcall(session.view.on_transcript_updated, session, text, mode)
    end, session.session_bootstrap)
  end
  return ok
end

local function clear_session_transcript(session, replacement_text)
  if not session or not session.transcript_path or session.transcript_path == "" then
    return false
  end

  session.current_stream_key = nil
  session.current_stream_heading = nil
  session.current_stream_at_line_start = nil
  session.current_stream_item_id = nil

  local text = normalize_text(replacement_text or "")
  local ok = write_session_transcript(session, text, "w")
  if ok then
    session.transcript_has_content = text ~= ""
    session.conversation_timeline = {}
    session.conversation_timeline_index = {}
    session.tool_calls = {}
    session.tool_timeline = {}
    session.tool_timeline_index = {}
    if sync_runtime_live_state then
      sync_runtime_live_state(session)
    end
  end
  return ok
end

local function rebuild_conversation_index(session)
  session.conversation_timeline = session.conversation_timeline or {}
  session.conversation_timeline_index = {}
  for idx, item in ipairs(session.conversation_timeline) do
    if type(item) == "table" and item.id and item.id ~= "" then
      session.conversation_timeline_index[item.id] = idx
    end
  end
  session.conversation_next_item_id = #session.conversation_timeline
end

local function rebuild_tool_index(session)
  session.tool_timeline = session.tool_timeline or {}
  session.tool_timeline_index = {}
  for idx, entry in ipairs(session.tool_timeline) do
    if type(entry) == "table" and entry.toolCallId and entry.toolCallId ~= "" then
      session.tool_timeline_index[entry.toolCallId] = idx
    end
  end
end

local function first_nonempty(...)
  for idx = 1, select("#", ...) do
    local value = select(idx, ...)
    if value ~= nil then
      local text = tostring(value)
      if text ~= "" then
        return value
      end
    end
  end
  return nil
end

local function first_number(...)
  for idx = 1, select("#", ...) do
    local value = tonumber(select(idx, ...))
    if value ~= nil then
      return value
    end
  end
  return nil
end

local function normalize_session_info(session_id, info, defaults)
  info = type(info) == "table" and vim.deepcopy(info) or {}
  defaults = type(defaults) == "table" and defaults or {}
  local meta = type(info._meta) == "table" and info._meta or {}
  local default_meta = type(defaults._meta) == "table" and defaults._meta or {}
  return {
    sessionId = tostring(session_id or info.sessionId or defaults.sessionId or ""),
    cwd = tostring(info.cwd or defaults.cwd or ""),
    title = first_nonempty(info.title, defaults.title, meta.title, default_meta.title),
    summary = first_nonempty(
      info.summary,
      info.description,
      info.subtitle,
      defaults.summary,
      defaults.description,
      defaults.subtitle,
      meta.summary,
      meta.description,
      meta.subtitle,
      meta.sessionSummary,
      default_meta.summary,
      default_meta.description,
      default_meta.subtitle,
      default_meta.sessionSummary
    ),
    status = first_nonempty(info.status, info.state, defaults.status, defaults.state, meta.status, meta.state, default_meta.status, default_meta.state),
    statusLabel = first_nonempty(
      info.statusLabel,
      info.stateLabel,
      info.label,
      defaults.statusLabel,
      defaults.stateLabel,
      defaults.label,
      meta.statusLabel,
      meta.stateLabel,
      meta.label,
      default_meta.statusLabel,
      default_meta.stateLabel,
      default_meta.label
    ),
    updatedAt = first_nonempty(info.updatedAt, defaults.updatedAt, meta.updatedAt, default_meta.updatedAt),
    _meta = vim.deepcopy(info._meta or defaults._meta or {}),
  }
end

local function update_session_info(session, info)
  if not session then
    return nil
  end

  local current = type(session.session_info) == "table" and vim.deepcopy(session.session_info) or {
    sessionId = session.session_id or "",
    cwd = session.cwd or "",
    title = nil,
    summary = nil,
    status = nil,
    statusLabel = nil,
    updatedAt = nil,
    _meta = {},
  }

  if type(info) == "table" then
    if info.title ~= nil then
      current.title = info.title
    end
    if info.summary ~= nil then
      current.summary = info.summary
    end
    if info.status ~= nil then
      current.status = info.status
    end
    if info.statusLabel ~= nil then
      current.statusLabel = info.statusLabel
    end
    if info.updatedAt ~= nil then
      current.updatedAt = info.updatedAt
    end
    if info._meta ~= nil then
      current._meta = vim.deepcopy(info._meta)
    end
    if info.cwd ~= nil and info.cwd ~= "" then
      current.cwd = info.cwd
    end
    if info.sessionId ~= nil and info.sessionId ~= "" then
      current.sessionId = info.sessionId
    end
  end

  session.session_info = normalize_session_info(current.sessionId or session.session_id, current, {
    cwd = session.cwd,
  })
  return session.session_info
end

local function update_usage_stats(session, update, model_id)
  if not session then
    return nil
  end

  local usage = type(update.usage) == "table" and update.usage or {}
  local stats = type(session.usage_stats) == "table" and session.usage_stats or {
    turn = {},
    cumulative = {},
    context = {},
  }

  local prompt_tokens = first_number(
    usage.promptTokens,
    usage.inputTokens,
    usage.prompt_tokens,
    usage.input_tokens
  )
  local completion_tokens = first_number(
    usage.completionTokens,
    usage.outputTokens,
    usage.completion_tokens,
    usage.output_tokens
  )
  local turn_total_tokens = first_number(
    usage.turnTokens,
    usage.turnTotalTokens,
    usage.responseTokens,
    usage.totalTokens
  )
  if turn_total_tokens == nil and (prompt_tokens ~= nil or completion_tokens ~= nil) then
    turn_total_tokens = (prompt_tokens or 0) + (completion_tokens or 0)
  end

  local context_used_tokens = first_number(
    usage.usedTokens,
    usage.contextUsedTokens,
    usage.contextTokens,
    usage.used_tokens
  )
  local context_total_tokens = first_number(
    usage.contextSize,
    usage.totalContextTokens,
    usage.contextWindow,
    usage.contextLimit
  )

  local cumulative_prompt_tokens = first_number(
    usage.totalPromptTokens,
    usage.promptTokensTotal,
    usage.cumulativePromptTokens
  )
  local cumulative_completion_tokens = first_number(
    usage.totalCompletionTokens,
    usage.completionTokensTotal,
    usage.cumulativeCompletionTokens
  )
  local cumulative_total_tokens = first_number(
    usage.totalSessionTokens,
    usage.sessionTokens,
    usage.cumulativeTokens
  )

  local provider_usage = first_nonempty(
    update.copilotUsage,
    usage.providerUsage,
    usage.usageLabel,
    usage.display,
    usage.summary
  )

  if cumulative_total_tokens == nil and (cumulative_prompt_tokens ~= nil or cumulative_completion_tokens ~= nil) then
    cumulative_total_tokens = (cumulative_prompt_tokens or 0) + (cumulative_completion_tokens or 0)
  end

  local snapshot_key = table.concat({
    tostring(model_id or ""),
    tostring(prompt_tokens or ""),
    tostring(completion_tokens or ""),
    tostring(turn_total_tokens or ""),
    tostring(context_used_tokens or ""),
    tostring(context_total_tokens or ""),
    tostring(provider_usage or ""),
  }, ":")

  if snapshot_key ~= stats.last_snapshot_key then
    stats.last_snapshot_key = snapshot_key
    if cumulative_prompt_tokens == nil and prompt_tokens ~= nil then
      stats.cumulative.prompt_tokens = (tonumber(stats.cumulative.prompt_tokens) or 0) + prompt_tokens
    elseif cumulative_prompt_tokens ~= nil then
      stats.cumulative.prompt_tokens = cumulative_prompt_tokens
    end

    if cumulative_completion_tokens == nil and completion_tokens ~= nil then
      stats.cumulative.completion_tokens = (tonumber(stats.cumulative.completion_tokens) or 0) + completion_tokens
    elseif cumulative_completion_tokens ~= nil then
      stats.cumulative.completion_tokens = cumulative_completion_tokens
    end

    if cumulative_total_tokens == nil and turn_total_tokens ~= nil then
      stats.cumulative.total_tokens = (tonumber(stats.cumulative.total_tokens) or 0) + turn_total_tokens
    elseif cumulative_total_tokens ~= nil then
      stats.cumulative.total_tokens = cumulative_total_tokens
    end
  end

  stats.turn = {
    prompt_tokens = prompt_tokens,
    completion_tokens = completion_tokens,
    total_tokens = turn_total_tokens,
  }
  stats.context = {
    used_tokens = context_used_tokens,
    total_tokens = context_total_tokens,
    remaining_tokens = (context_used_tokens ~= nil and context_total_tokens ~= nil)
        and math.max(context_total_tokens - context_used_tokens, 0)
      or nil,
  }
  stats.provider_usage = provider_usage and tostring(provider_usage) or nil
  stats.model_id = model_id
  stats.updated_at = os.time()
  session.usage_stats = stats
  return stats
end

local function restore_switch_snapshot(session, snapshot)
  if not session or type(snapshot) ~= "table" then
    return false
  end

  if snapshot.preserve_transcript == true then
    local previous = session.pending_switch_history
    local transcript_lines = vim.deepcopy(snapshot.transcript_lines or {})
    local conversation_timeline = vim.deepcopy(snapshot.conversation_timeline or {})
    local tool_timeline = vim.deepcopy(snapshot.tool_timeline or {})
    local carryover_label = snapshot.carryover_label

    if previous and type(previous) == "table" then
      local merged_lines = vim.deepcopy(previous.transcript_lines or {})
      if #merged_lines > 0 and #transcript_lines > 0 and merged_lines[#merged_lines] ~= "" then
        merged_lines[#merged_lines + 1] = ""
      end
      vim.list_extend(merged_lines, transcript_lines)
      transcript_lines = merged_lines

      local merged_conversation = vim.deepcopy(previous.conversation_timeline or {})
      vim.list_extend(merged_conversation, conversation_timeline)
      conversation_timeline = merged_conversation

      local merged_tools = vim.deepcopy(previous.tool_timeline or {})
      vim.list_extend(merged_tools, tool_timeline)
      tool_timeline = merged_tools

      if previous.carryover_label and previous.carryover_label ~= "" then
        carryover_label = carryover_label and carryover_label ~= ""
            and (previous.carryover_label .. " + " .. carryover_label)
          or previous.carryover_label
      end

      if previous.transcript_path and previous.transcript_path ~= "" and previous.transcript_path ~= snapshot.transcript_path then
        pcall(vim.fn.delete, previous.transcript_path)
      end
    end

    session.pending_switch_history = {
      provider_from = snapshot.provider_from,
      carryover_label = carryover_label,
      transcript_lines = transcript_lines,
      transcript_path = snapshot.transcript_path,
      conversation_timeline = conversation_timeline,
      tool_timeline = tool_timeline,
    }

    if snapshot.transition_message and snapshot.transition_message ~= "" then
      append_block(session, "System", snapshot.transition_message)
    elseif sync_runtime_session then
      sync_runtime_session(session)
    end

    return true
  end

  clear_pending_switch_history(session)
  session.current_stream_key = nil
  session.current_stream_heading = nil
  session.current_stream_at_line_start = nil
  session.current_stream_item_id = nil
  session.tool_calls = {}

  session.conversation_timeline = vim.deepcopy(snapshot.conversation_timeline or {})
  session.tool_timeline = vim.deepcopy(snapshot.tool_timeline or {})
  rebuild_conversation_index(session)
  rebuild_tool_index(session)

  local lines = type(snapshot.transcript_lines) == "table" and vim.deepcopy(snapshot.transcript_lines) or {}
  local text = normalize_text(table.concat(lines, "\n"))
  local ok = write_session_transcript(session, text, "w")
  if ok then
    session.transcript_has_content = text ~= ""
  end

  session.pending_switch_history = {
    provider_from = snapshot.provider_from,
    carryover_label = snapshot.carryover_label,
    transcript_lines = vim.deepcopy(snapshot.transcript_lines or {}),
    transcript_path = snapshot.transcript_path,
    conversation_timeline = vim.deepcopy(snapshot.conversation_timeline or {}),
    tool_timeline = vim.deepcopy(snapshot.tool_timeline or {}),
  }

  if snapshot.transition_message and snapshot.transition_message ~= "" then
    append_block(session, "System", snapshot.transition_message)
  elseif sync_runtime_session then
    sync_runtime_session(session)
  end

  return ok
end

clear_pending_switch_history = function(session)
  if not session then
    return
  end
  local pending = session.pending_switch_history
  if pending and pending.transcript_path and pending.transcript_path ~= "" then
    pcall(vim.fn.delete, pending.transcript_path)
  end
  session.pending_switch_history = nil
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

local function normalize_config_key(value)
  return tostring(value or ""):lower():gsub("[^%w]+", "")
end

local function find_config_option(session, keys)
  if not session or type(session.config_options) ~= "table" then
    return nil
  end

  keys = type(keys) == "table" and keys or { keys }
  for _, option in ipairs(session.config_options) do
    if type(option) == "table" then
      local option_id = normalize_config_key(option.id)
      local category = normalize_config_key(option.category)
      local name = normalize_config_key(option.name)
      for _, key in ipairs(keys) do
        local expected = normalize_config_key(key)
        if expected ~= "" and (option_id == expected or category == expected or name == expected) then
          return option
        end
      end
    end
  end

  return nil
end

local function compact_config_value(value)
  local text = tostring(value or "")
  if text == "" then
    return ""
  end
  return text:gsub("^https://agentclientprotocol%.com/protocol/session%-modes#", "")
end

local function current_config_label(session, keys)
  local option = find_config_option(session, keys)
  if not option then
    return nil
  end

  local current = option.currentValue
  if current == nil or current == "" then
    return nil
  end

  for _, choice in ipairs(option.options or {}) do
    if type(choice) == "table" and choice.value == current then
      return compact_config_value(choice.name or current)
    end
  end

  return compact_config_value(current)
end

local function provider_heading_label(session)
  local info = session and session.agent_info or {}
  local name = info.title or info.name or session.agent_name or "ACP"
  local parts = { tostring(name) }

  local model = current_config_label(session, { "model" })
  if model and model ~= "" then
    parts[#parts + 1] = model
  end

  local reasoning = current_config_label(session, { "thought_level", "reasoning_effort" })
  if reasoning and reasoning ~= "" and reasoning:lower() ~= "none" then
    parts[#parts + 1] = reasoning
  end

  return table.concat(parts, " ")
end

local function assistant_heading_label(session)
  local label = provider_heading_label(session)
  if label == "" then
    return "Assistant"
  end
  return label
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

local function normalize_available_commands(commands)
  local out = {}
  for _, command in ipairs(commands or {}) do
    if type(command) == "table" and command.name and command.name ~= "" then
      local desc = tostring(command.description or command.doc or "")
      local hint = command.input and command.input.hint or nil
      table.insert(out, {
        name = tostring(command.name),
        label = "/" .. tostring(command.name),
        desc = desc,
        category = first_nonempty(command.category, command.group),
        input_hint = hint and tostring(hint) or nil,
        input_required = command.input and command.input.required == true or false,
        input_placeholder = command.input and command.input.placeholder or nil,
      })
    end
  end
  return out
end

local function extract_slash_command_name(text)
  local trimmed = normalize_text(text):gsub("^%s+", ""):gsub("%s+$", "")
  return trimmed:match("^/([%w_-]+)")
end

local function session_has_available_command(session, name)
  if not session or type(session.available_commands) ~= "table" then
    return false
  end
  local expected = "/" .. tostring(name)
  for _, command in ipairs(session.available_commands) do
    if type(command) == "table" and command.label == expected then
      return true
    end
  end
  return false
end

local function note_unadvertised_slash_command(session, prompt)
  local name = extract_slash_command_name(prompt)
  if not name or session_has_available_command(session, name) then
    return
  end

  session.warned_unadvertised_commands = session.warned_unadvertised_commands or {}
  if session.warned_unadvertised_commands[name] then
    return
  end
  session.warned_unadvertised_commands[name] = true

  append_block(
    session,
    "System",
    string.format(
      "ACP did not advertise /%s for this session. Picker-style CLI slash commands are not available over ACP, so this input will be handled as plain prompt text.",
      name
    )
  )
end

sync_runtime_live_state = function(session)
  if not session or session.runtime_sync_disabled == true then
    return
  end
  local ok_state, state = pcall(require, "lazyagent.logic.state")
  if not ok_state or not state or not state.sessions or not state.sessions[session.agent_name] then
    return
  end

  local runtime = state.sessions[session.agent_name]
  runtime.acp_tool_timeline = session.tool_timeline or {}
  runtime.acp_conversation_timeline = session.conversation_timeline or {}
end

sync_runtime_session = function(session)
  if not session or session.runtime_sync_disabled == true then
    return
  end
  local ok_state, state = pcall(require, "lazyagent.logic.state")
  if not ok_state or not state or not state.sessions or not state.sessions[session.agent_name] then
    return
  end

  local runtime = state.sessions[session.agent_name]
  sync_runtime_live_state(session)
  runtime.acp_available_commands = vim.deepcopy(session.available_commands or {})
  runtime.acp_config_options = vim.deepcopy(session.config_options or {})
  runtime.acp_session_id = session.session_id
  runtime.acp_session_info = vim.deepcopy(session.session_info or {})
  runtime.acp_transcript_path = session.transcript_path
  runtime.acp_agent_info = vim.deepcopy(session.agent_info or {})
  runtime.acp_agent_capabilities = vim.deepcopy(session.agent_capabilities or {})
  runtime.acp_session_capabilities = vim.deepcopy((session.agent_capabilities and session.agent_capabilities.sessionCapabilities) or {})
  runtime.acp_model_catalog = vim.deepcopy(session.model_catalog or {})
  runtime.acp_mode_catalog = vim.deepcopy(session.mode_catalog or {})
  runtime.acp_usage_stats = vim.deepcopy(session.usage_stats or {})
  runtime.acp_ready = session.ready == true
  runtime.acp_failed = session.failed == true
  runtime.acp_supports_embedded_context = session.prompt_supports_embedded_context == true
  runtime.acp_mcp_server_count = session.mcp_server_count or ((session.mcp_url and session.mcp_url ~= "") and 1 or 0)
  runtime.footer_animation = session.footer_animation
  runtime.acp_permission_rules = vim.deepcopy(session.permission_rules or {})
  runtime.acp_auto_switch = vim.deepcopy(session.auto_switch or {})
  runtime.acp_manual_config_overrides = vim.deepcopy(session.manual_config_overrides or {})

  pcall(function()
    require("lazyagent.acp.view_buffer").refresh_agent_footers(session.agent_name, { force = true })
  end)
end

local function normalize_config_key(value)
  return tostring(value or ""):lower():gsub("[^%w]+", "")
end

local function config_option_key(option)
  if type(option) ~= "table" then
    return nil
  end
  return option.category or option.id or option.name
end

local function config_option_title(option)
  if type(option) ~= "table" then
    return "ACP setting"
  end
  return option.name or option.label or option.id or option.category or "ACP setting"
end

local function config_option_description(option)
  if type(option) ~= "table" then
    return nil
  end
  return first_nonempty(option.description, option.doc, option.helpText, option.help)
end

local function config_option_category(option)
  if type(option) ~= "table" then
    return nil
  end
  local category = first_nonempty(option.category, option.group)
  if not category then
    return nil
  end
  category = tostring(category)
  local title = tostring(config_option_title(option))
  if category == "" or category == title then
    return nil
  end
  return category
end

local function config_option_kind(option)
  local option_type = normalize_config_key(type(option) == "table" and option.type or "")
  if option_type == "select" or option_type == "multiselect" then
    if type(option.options) == "table" and #option.options > 0 then
      return "select"
    end
  end
  if option_type == "boolean" or option_type == "bool" or option_type == "toggle" then
    return "toggle"
  end
  return option_type ~= "" and option_type or nil
end

local function parse_boolean(value)
  if type(value) == "boolean" then
    return value
  end
  if value == nil then
    return nil
  end
  local normalized = tostring(value):lower()
  if normalized == "true" or normalized == "1" or normalized == "yes" or normalized == "on" or normalized == "enabled" then
    return true
  end
  if normalized == "false" or normalized == "0" or normalized == "no" or normalized == "off" or normalized == "disabled" then
    return false
  end
  return nil
end

local function config_option_current_name(option)
  if type(option) ~= "table" then
    return nil
  end
  local current = option.currentValue
  if current == nil or current == "" then
    return nil
  end
  for _, choice in ipairs(option.options or {}) do
    if type(choice) == "table" and choice.value == current then
      return choice.name or tostring(current)
    end
  end
  if config_option_kind(option) == "toggle" then
    local boolean = parse_boolean(current)
    if boolean ~= nil then
      return boolean and "Enabled" or "Disabled"
    end
  end
  return tostring(current)
end

local find_config_option

local function followup_picker_for_option(session, option)
  if normalize_config_key(config_option_key(option)) ~= "model" and normalize_config_key(option.id) ~= "model" then
    return nil
  end

  for _, key in ipairs({
    "thought_level",
    "thought-level",
    "thoughtLevel",
    "reasoning_effort",
    "reasoning-effort",
    "reasoningEffort",
  }) do
    local option_match = find_config_option(session, key)
    if option_match then
      return option_match
    end
  end

  return nil
end

local function selectable_config_options(session, category)
  local out = {}
  for _, option in ipairs(session.config_options or {}) do
    local kind = config_option_kind(option)
    if type(option) == "table" and (kind == "select" or kind == "toggle") then
      local key = config_option_key(option)
      if not category or key == category or option.id == category then
        table.insert(out, option)
      end
    end
  end
  table.sort(out, function(a, b)
    return config_option_title(a):lower() < config_option_title(b):lower()
  end)
  return out
end

local function move_current_choice_to_head(option)
  local ordered = {}
  local current = option and option.currentValue or nil
  for _, choice in ipairs(option.options or {}) do
    if type(choice) == "table" and choice.value == current then
      table.insert(ordered, choice)
    end
  end
  for _, choice in ipairs(option.options or {}) do
    if type(choice) == "table" and choice.value ~= current then
      table.insert(ordered, choice)
    end
  end
  return ordered
end

local function config_option_choice_items(option)
  if config_option_kind(option) == "toggle" then
    local base_description = config_option_description(option)
    return {
      {
        name = first_nonempty(option.enabledLabel, option.trueLabel, "Enabled"),
        value = true,
        description = first_nonempty(option.enabledDescription, option.trueDescription, base_description),
      },
      {
        name = first_nonempty(option.disabledLabel, option.falseLabel, "Disabled"),
        value = false,
        description = first_nonempty(option.disabledDescription, option.falseDescription, base_description),
      },
    }
  end
  return move_current_choice_to_head(option)
end

local function config_option_picker_label(option)
  local label = config_option_title(option)
  local current = config_option_current_name(option)
  local meta = {}
  local category = config_option_category(option)
  local kind = config_option_kind(option)

  if current and current ~= "" then
    label = string.format("%s (%s)", label, current)
  end
  if category and category ~= "" then
    meta[#meta + 1] = tostring(category)
  end
  if kind and kind ~= "" and kind ~= "select" then
    meta[#meta + 1] = tostring(kind)
  end
  if #meta > 0 then
    label = string.format("%s [%s]", label, table.concat(meta, ", "))
  end

  local description = config_option_description(option)
  if description and description ~= "" then
    label = label .. " - " .. description
  end
  return label
end

local function queue_after_ready(session, callback)
  session.on_ready_actions = session.on_ready_actions or {}
  table.insert(session.on_ready_actions, callback)
end

local function apply_config_option_choice(session, option, choice, on_done, opts)
  opts = opts or {}
  if type(on_done) ~= "function" then
    on_done = function() end
  end
  if not session.ready or session.failed or not session.client then
    append_block(session, "Error", "ACP session is not ready for configuration changes.")
    on_done(false)
    return false
  end

  local label = config_option_title(option)
  local key = config_option_key(option)
  local source = opts.source or "manual"
  local method = "set_config_option"
  if session.client._legacy_api then
    if key == "mode" and type(session.client.set_mode) == "function" then
      method = "set_mode"
    elseif key == "model" and type(session.client.set_model) == "function" then
      method = "set_model"
    end
  end

  local callback = function(config_options, err)
    if err then
      append_block(session, "Error", string.format("Failed to update %s: %s", label, err.message or tostring(err)))
      on_done(false, err)
      return
    end
    session.config_options = vim.deepcopy(config_options or session.client.config_options or session.config_options or {})
    session.manual_config_overrides = session.manual_config_overrides or {}
    session.auto_switch_state = session.auto_switch_state or {}
    if source == "manual" and key then
      session.manual_config_overrides[key] = true
    elseif source == "auto" and key then
      session.auto_switch_state[key] = choice.value
    end
    sync_runtime_session(session)
    local success_message = opts.success_message
    if success_message == nil then
      success_message = string.format("%s set to %s", label, choice.name or tostring(choice.value))
    end
    if success_message ~= false and success_message ~= "" then
      append_block(session, "System", success_message)
    end
    on_done(true)
  end

  if method == "set_config_option" then
    session.client:set_config_option(option.id, choice.value, callback)
  elseif method == "set_mode" then
    session.client:set_mode(choice.value, callback)
  else
    session.client:set_model(choice.value, callback)
  end

  return true
end

find_config_option = function(session, key)
  local expected = normalize_config_key(key)
  for _, option in ipairs(session.config_options or {}) do
    if type(option) == "table" then
      local option_key = normalize_config_key(config_option_key(option))
      local option_id = normalize_config_key(option.id)
      if expected ~= "" and (option_key == expected or option_id == expected) then
        return option
      end
    end
  end
  return nil
end

local function find_config_choice(option, value)
  if type(option) ~= "table" or value == nil or value == "" then
    return nil
  end
  local expected = tostring(value)
  for _, choice in ipairs(option.options or {}) do
    if type(choice) == "table" and tostring(choice.value) == expected then
      return choice
    end
  end
  return nil
end

local function choice_display_name(choice)
  if type(choice) ~= "table" then
    return tostring(choice or "")
  end
  return choice.name or tostring(choice.value or "")
end

local function session_source_bufnr(session)
  local bufnr = session and session.agent_cfg and (session.agent_cfg.source_bufnr or session.agent_cfg.origin_bufnr) or nil
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    return bufnr
  end
  return nil
end

local function build_auto_switch_context(session, prompt)
  local bufnr = session_source_bufnr(session)
  local path = bufnr and vim.api.nvim_buf_get_name(bufnr) or ""
  local filetype = (bufnr and vim.bo[bufnr] and vim.bo[bufnr].filetype) or ""
  local diagnostics = bufnr and transforms.gather_diagnostics(bufnr) or {}
  local counts = {
    diagnostics = #diagnostics,
    errors = 0,
    warnings = 0,
    infos = 0,
    hints = 0,
  }

  for _, item in ipairs(diagnostics or {}) do
    local severity = tostring(item.severity or ""):upper()
    if severity == "ERROR" then
      counts.errors = counts.errors + 1
    elseif severity == "WARN" or severity == "WARNING" then
      counts.warnings = counts.warnings + 1
    elseif severity == "INFO" then
      counts.infos = counts.infos + 1
    elseif severity == "HINT" then
      counts.hints = counts.hints + 1
    end
  end

  return {
    agent = tostring(session and session.agent_name or ""),
    cwd = tostring(session and (session.root_dir or session.cwd) or vim.fn.getcwd()),
    path = path,
    filetype = filetype,
    text = tostring(prompt or ""),
    prompt_length = vim.fn.strchars(tostring(prompt or "")),
    prompt_lines = select(2, tostring(prompt or ""):gsub("\n", "\n")) + 1,
    diagnostics = counts.diagnostics,
    errors = counts.errors,
    warnings = counts.warnings,
    infos = counts.infos,
    hints = counts.hints,
  }
end

local function auto_switch_rule_label(rule, idx)
  if type(rule) ~= "table" then
    return string.format("rule #%d", idx)
  end
  return tostring(rule.name or rule.label or rule.id or ("rule #" .. tostring(idx)))
end

local function auto_switch_rule_matches(context, rule)
  if type(rule) ~= "table" then
    return false
  end
  if not matches_exact({ context.agent }, rule.agent) then
    return false
  end
  if not matches_pattern({ context.agent }, rule.agent_pattern) then
    return false
  end
  if not matches_exact({ context.cwd }, rule.cwd) then
    return false
  end
  if not matches_pattern({ context.cwd }, rule.cwd_pattern) then
    return false
  end
  if not matches_exact({ context.filetype }, rule.filetype) then
    return false
  end
  if not matches_pattern({ context.filetype }, rule.filetype_pattern) then
    return false
  end
  if not matches_exact({ context.path }, rule.path) then
    return false
  end
  if not matches_pattern({ context.path }, rule.path_pattern) then
    return false
  end
  if not matches_pattern({ context.text }, rule.text_pattern) then
    return false
  end
  if rule.prompt_length_min and context.prompt_length < tonumber(rule.prompt_length_min) then
    return false
  end
  if rule.prompt_length_max and context.prompt_length > tonumber(rule.prompt_length_max) then
    return false
  end
  if rule.prompt_lines_min and context.prompt_lines < tonumber(rule.prompt_lines_min) then
    return false
  end
  if rule.prompt_lines_max and context.prompt_lines > tonumber(rule.prompt_lines_max) then
    return false
  end
  if rule.diagnostics_min and context.diagnostics < tonumber(rule.diagnostics_min) then
    return false
  end
  if rule.diagnostics_max and context.diagnostics > tonumber(rule.diagnostics_max) then
    return false
  end
  if rule.errors_min and context.errors < tonumber(rule.errors_min) then
    return false
  end
  if rule.errors_max and context.errors > tonumber(rule.errors_max) then
    return false
  end
  if rule.warnings_min and context.warnings < tonumber(rule.warnings_min) then
    return false
  end
  if rule.warnings_max and context.warnings > tonumber(rule.warnings_max) then
    return false
  end
  return true
end

local function resolve_auto_switch_operations(session, prompt)
  local latest_cfg = acp_logic.resolve_config(session.agent_cfg or {})
  session.auto_switch = vim.deepcopy(latest_cfg.auto_switch or {})
  sync_runtime_session(session)

  local auto_cfg = session.auto_switch or {}
  if auto_cfg.enabled ~= true then
    return {}
  end

  local context = build_auto_switch_context(session, prompt)
  local operations = {}
  local preserve_manual = auto_cfg.preserve_manual ~= false

  for _, spec in ipairs({
    { key = "mode", rules = auto_cfg.mode_rules, value_key = "mode" },
    { key = "model", rules = auto_cfg.model_rules, value_key = "model" },
  }) do
    if not (preserve_manual and session.manual_config_overrides and session.manual_config_overrides[spec.key]) then
      local option = find_config_option(session, spec.key)
      if option then
        for idx, rule in ipairs(spec.rules or {}) do
          if auto_switch_rule_matches(context, rule) then
            local desired = rule.value or rule[spec.value_key]
            local choice = find_config_choice(option, desired)
            local current = tostring(option.currentValue or "")
            if choice and tostring(choice.value or "") ~= current then
              operations[#operations + 1] = {
                key = spec.key,
                option = option,
                choice = choice,
                rule_label = auto_switch_rule_label(rule, idx),
              }
            end
            break
          end
        end
      end
    end
  end

  return operations
end

local function maybe_apply_auto_switch(session, prompt, done)
  done = done or function() end
  if not session or session.failed or not session.ready or not session.client then
    done()
    return
  end

  local operations = resolve_auto_switch_operations(session, prompt)
  if #operations == 0 then
    done()
    return
  end

  local function step(index)
    local item = operations[index]
    if not item then
      done()
      return
    end

    apply_config_option_choice(session, item.option, item.choice, function()
      step(index + 1)
    end, {
      source = "auto",
      success_message = string.format(
        "Auto %s -> %s (%s)",
        item.key,
        choice_display_name(item.choice),
        item.rule_label
      ),
    })
  end

  step(1)
end

local function apply_initial_session_config(session, done)
  done = done or function() end
  if session.initial_config_applied then
    done()
    return
  end
  session.initial_config_applied = true

  local pending = {}
  if session.default_mode and session.default_mode ~= "" then
    table.insert(pending, { key = "mode", value = session.default_mode, title = "mode" })
  end
  if session.initial_model and session.initial_model ~= "" then
    table.insert(pending, { key = "model", value = session.initial_model, title = "model" })
  end

  local function step(index)
    local item = pending[index]
    if not item then
      done()
      return
    end

    local option = find_config_option(session, item.key)
    if not option then
      step(index + 1)
      return
    end

    local choice = find_config_choice(option, item.value)
    if not choice then
      append_block(session, "System", string.format("ACP %s `%s` is not available for this session.", item.title, item.value))
      step(index + 1)
      return
    end

    if tostring(option.currentValue or "") == tostring(choice.value) then
      step(index + 1)
      return
    end

    apply_config_option_choice(session, option, choice, function()
      step(index + 1)
    end, { source = "initial" })
  end

  step(1)
end

local function show_config_value_picker(session, option)
  local items = config_option_choice_items(option)
  if #items == 0 then
    append_block(session, "System", string.format("%s does not expose any selectable values.", config_option_title(option)))
    return false
  end

  local function open_followup_picker()
    local followup = followup_picker_for_option(session, option)
    if followup then
      vim.schedule(function()
        show_config_value_picker(session, followup)
      end)
      return true
    end
    return false
  end

  local current = option.currentValue
  vim.ui.select(items, {
    prompt = "Select " .. config_option_title(option) .. ":",
    format_item = function(item)
      local prefix = (tostring(item.value) == tostring(current)) and "● " or "  "
      local suffix = item.description and item.description ~= "" and (": " .. item.description) or ""
      return prefix .. (item.name or tostring(item.value)) .. suffix
    end,
  }, function(choice)
    if not choice then
      return
    end
    if choice.value == current then
      open_followup_picker()
      return
    end
    apply_config_option_choice(session, option, choice, function(updated)
      if not updated then
        return
      end

      open_followup_picker()
    end)
  end)

  return true
end

local function show_config_picker_for_session(session, category)
  if not session then
    return false
  end

  local label = category and ("`" .. category .. "`") or "ACP config"
  if session.failed then
    append_block(session, "Error", "ACP session is disconnected. Restart the agent session to continue.")
    return false
  end

  if not session.ready or not session.client then
    queue_after_ready(session, function()
      show_config_picker_for_session(session, category)
    end)
    append_block(session, "System", string.format("ACP session is still connecting. %s picker will open when ready.", label))
    return true
  end

  local options = selectable_config_options(session, category)
  if #options == 0 then
    append_block(session, "System", string.format("This ACP session does not expose any %s options.", label))
    return false
  end

  if #options == 1 then
    return show_config_value_picker(session, options[1])
  end

  vim.ui.select(options, {
    prompt = "Choose ACP setting:",
    format_item = function(item)
      return config_option_picker_label(item)
    end,
  }, function(choice)
    if not choice then
      return
    end
    show_config_value_picker(session, choice)
  end)

  return true
end

local function command_palette_items(session)
  local out = {}
  local advertised = {}

  for _, command in ipairs(session and session.available_commands or {}) do
    if type(command) == "table" and command.label and command.label ~= "" then
      advertised[command.label] = true
    end
  end

  for _, command in ipairs(local_commands.merged_entries(session, session and session.available_commands or {})) do
    if type(command) == "table" and command.label then
      local source = advertised[command.label] and "agent" or "local"
      out[#out + 1] = vim.tbl_extend("force", { source = source }, vim.deepcopy(command))
    end
  end

  for _, command in ipairs(agent_logic.get_visible_slash_commands(session and session.agent_name, session)) do
    if type(command) == "table" and command.label then
      local exists = false
      for _, item in ipairs(out) do
        if item.label == command.label then
          exists = true
          break
        end
      end
      if not exists then
        local source = advertised[command.label] and "agent" or "local"
        out[#out + 1] = vim.tbl_extend("force", { source = source }, vim.deepcopy(command))
      end
    end
  end

  return out
end

local function show_command_palette_for_session(session, submit)
  if not session then
    return false
  end

  if session.failed then
    append_block(session, "Error", "ACP session is disconnected. Restart the agent session to continue.")
    return false
  end

  if not session.ready or not session.client then
    queue_after_ready(session, function()
      show_command_palette_for_session(session, submit)
    end)
    append_block(session, "System", "ACP session is still connecting. Command palette will open when ready.")
    return true
  end

  local items = command_palette_items(session)
  if #items == 0 then
    append_block(session, "System", "This ACP session does not expose any slash commands yet.")
    return false
  end

  vim.ui.select(items, {
    prompt = "Choose ACP command:",
    format_item = function(item)
      local source = item.source or "agent"
      local meta = { source }
      if item.category and item.category ~= "" then
        meta[#meta + 1] = tostring(item.category)
      end
      if item.input_required then
        meta[#meta + 1] = "args"
      elseif item.input_hint and item.input_hint ~= "" then
        meta[#meta + 1] = "input"
      end
      local details = {}
      if item.desc and item.desc ~= "" then
        details[#details + 1] = tostring(item.desc)
      end
      if item.input_hint and item.input_hint ~= "" then
        details[#details + 1] = "Input: " .. tostring(item.input_hint)
      elseif item.input_placeholder and item.input_placeholder ~= "" then
        details[#details + 1] = "Input: " .. tostring(item.input_placeholder)
      end
      local desc = #details > 0 and (" - " .. table.concat(details, " · ")) or ""
      return string.format("%s [%s]%s", item.label, table.concat(meta, ", "), desc)
    end,
  }, function(choice)
    if not choice or not choice.label or choice.label == "" then
      return
    end
    submit(choice.label)
  end)

  return true
end

local function render_tool_timeline_detail(entry)
  local tool = entry and entry.tool or {}
  local lines = {
    "# ACP Tool Timeline",
    "",
    "ID: " .. tostring(entry and entry.toolCallId or ""),
    "Title: " .. tostring(entry and entry.title or tool.title or ""),
    "Heading: " .. tostring(entry and entry.heading or ""),
    "Status: " .. tostring(entry and entry.status or tool.status or ""),
  }

  local paths = type(entry and entry.paths) == "table" and entry.paths or extract_tool_paths(tool)
  if #paths > 0 then
    lines[#lines + 1] = "Paths:"
    for _, path in ipairs(paths) do
      lines[#lines + 1] = "- " .. path
    end
  end

  local body = tostring(entry and entry.rendered_content or "")
  if body == "" then
    body = render_tool_content(tool.content)
  end
  if body ~= "" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Content:"
    vim.list_extend(lines, vim.split(body, "\n", { plain = true }))
  end

  local raw_output = tostring(entry and entry.rendered_raw_output or "")
  if raw_output == "" then
    raw_output = render_tool_raw_output(tool.rawOutput)
  end
  if raw_output ~= "" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Raw output:"
    vim.list_extend(lines, vim.split(raw_output, "\n", { plain = true }))
  end

  return lines
end

local function normalize_buffer_lines(lines)
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
  return normalized
end

local function is_standard_window(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end

  local ok_cfg, cfg = pcall(vim.api.nvim_win_get_config, win)
  if not ok_cfg or (cfg and cfg.relative ~= "") then
    return false
  end

  local ok_buf, buf = pcall(vim.api.nvim_win_get_buf, win)
  if not ok_buf or not buf or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end

  local ok_pane, pane_id = pcall(vim.api.nvim_buf_get_var, buf, "lazyagent_acp_pane_id")
  if ok_pane and pane_id ~= nil then
    return false
  end

  local buftype = vim.bo[buf].buftype
  return buftype == "" or buftype == "acwrite"
end

local function preferred_output_window(session)
  local candidates = {
    session and session.view_state and session.view_state.source_winid or nil,
  }

  local ok_current, current = pcall(vim.api.nvim_get_current_win)
  if ok_current then
    candidates[#candidates + 1] = current
  end

  for _, win in ipairs(candidates) do
    if is_standard_window(win) then
      return win
    end
  end

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if is_standard_window(win) then
      return win
    end
  end

  return nil
end

local function open_output_window(session)
  local target = preferred_output_window(session)
  if target and vim.api.nvim_win_is_valid(target) then
    pcall(vim.api.nvim_set_current_win, target)
    pcall(vim.cmd, "belowright split")
    return vim.api.nvim_get_current_win()
  end

  pcall(vim.cmd, "tabnew")
  return vim.api.nvim_get_current_win()
end

local function open_output_buffer(session, name, filetype, lines)
  local win = open_output_window(session)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end

  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_win_set_buf(win, buf)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].undofile = false
  vim.bo[buf].modifiable = true
  vim.bo[buf].filetype = filetype or "markdown"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, normalize_buffer_lines(lines or {}))
  if name and name ~= "" then
    vim.api.nvim_buf_set_name(buf, string.format("%s [%d]", name, buf))
  end
  vim.bo[buf].modified = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.keymap.set("n", "q", function()
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_win_close, 0, false)
    end
  end, { buffer = buf, silent = true, noremap = true, desc = "Close ACP output" })
  return true
end

local function open_tool_timeline_buffer(session, entry)
  open_output_buffer(
    session,
    "ACP Tool Output " .. sanitize_filename_component(entry.toolCallId or "tool"),
    "markdown",
    render_tool_timeline_detail(entry)
  )
end

local function show_tool_timeline_for_session(session)
  if not session then
    return false
  end

  local timeline = session.tool_timeline or {}
  if #timeline == 0 then
    append_block(session, "System", "No ACP tool calls have been recorded for this session yet.")
    return false
  end

  vim.ui.select(timeline, {
    prompt = "ACP tool timeline:",
    format_item = function(item)
      local pin = item.pinned and "📌 " or ""
      local status = item.status and item.status ~= "" and (" [" .. item.status .. "]") or ""
      local summary = item.summary and item.summary ~= "" and (" - " .. item.summary) or ""
      return string.format("%s%02d. %s%s%s", pin, item.seq or 0, item.title or item.toolCallId or "tool", status, summary)
    end,
  }, function(choice)
    if not choice then
      return
    end
    open_tool_timeline_buffer(session, choice)
  end)

  return true
end

local function open_report_buffer(session, name, filetype, lines)
  open_output_buffer(session, name, filetype, lines)
end

local function render_capability_report(session)
  local info = session and session.agent_info or {}
  local lines = {
    "# ACP Capability Summary",
    "",
    "## Session",
    string.format("- Agent: %s", tostring(session and session.agent_name or "")),
    string.format("- Provider: %s", tostring(info.title or info.name or session.agent_name or "ACP")),
    string.format("- Version: %s", tostring(info.version or "unknown")),
    string.format("- Ready: %s", tostring(session and session.ready == true)),
    string.format("- Embedded context: %s", tostring(session and session.prompt_supports_embedded_context == true)),
    string.format("- MCP servers: %d", tonumber(session and session.mcp_server_count or 0) or 0),
    string.format("- Root: %s", tostring(session and (session.root_dir or session.cwd) or "")),
  }

  if session and session.session_id then
    lines[#lines + 1] = string.format("- Session ID: %s", session.session_id)
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "## Local ACP actions"
  for _, command in ipairs(local_commands.entries(session)) do
    lines[#lines + 1] = string.format("- %s — %s", command.label, command.desc or "")
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "## Config options"
  if #(session and session.config_options or {}) == 0 then
    lines[#lines + 1] = "- None"
  else
    for _, option in ipairs(session.config_options or {}) do
      if type(option) == "table" then
        local detail = {
          tostring(config_option_current_name(option) or "unset"),
        }
        local kind = config_option_kind(option)
        if kind then
          detail[#detail + 1] = kind
        end
        local category = config_option_category(option)
        if category then
          detail[#detail + 1] = category
        end
        if type(option.options) == "table" and #option.options > 0 then
          detail[#detail + 1] = string.format("%d choices", #option.options)
        end
        local description = config_option_description(option)
        local suffix = description and description ~= "" and (" — " .. description) or ""
        lines[#lines + 1] = string.format("- %s: %s%s", config_option_title(option), table.concat(detail, " / "), suffix)
      end
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "## Slash commands"
  local merged_commands = agent_logic.get_visible_slash_commands(session and session.agent_name, session)
  if #merged_commands == 0 then
    lines[#lines + 1] = "- None advertised"
  else
    for _, command in ipairs(merged_commands) do
      local detail = {}
      if command.category and command.category ~= "" then
        detail[#detail + 1] = tostring(command.category)
      end
      if command.input_required then
        detail[#detail + 1] = "args"
      elseif command.input_hint and command.input_hint ~= "" then
        detail[#detail + 1] = "input"
      end
      local desc = command.desc or ""
      if command.input_hint and command.input_hint ~= "" then
        desc = desc ~= "" and (desc .. " Input: " .. tostring(command.input_hint)) or ("Input: " .. tostring(command.input_hint))
      end
      local meta = #detail > 0 and (" [" .. table.concat(detail, ", ") .. "]") or ""
      local suffix = desc ~= "" and (" — " .. desc) or ""
      lines[#lines + 1] = string.format("- %s%s%s", command.label or "", meta, suffix)
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "## Auto switch"
  local auto_cfg = session and session.auto_switch or {}
  lines[#lines + 1] = string.format("- Enabled: %s", tostring(auto_cfg and auto_cfg.enabled == true))
  lines[#lines + 1] = string.format("- Preserve manual: %s", tostring(auto_cfg and auto_cfg.preserve_manual ~= false))
  lines[#lines + 1] = string.format("- Mode rules: %d", #(auto_cfg and auto_cfg.mode_rules or {}))
  lines[#lines + 1] = string.format("- Model rules: %d", #(auto_cfg and auto_cfg.model_rules or {}))
  local overrides = session and session.manual_config_overrides or {}
  if next(overrides) then
    lines[#lines + 1] = "- Manual overrides: " .. table.concat(vim.tbl_keys(overrides), ", ")
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "## Agent capabilities"
  lines[#lines + 1] = "```lua"
  vim.list_extend(lines, vim.split(vim.inspect(session and session.agent_capabilities or {}), "\n", { plain = true }))
  lines[#lines + 1] = "```"

  return lines
end

local function show_capabilities_for_session(session)
  if not session then
    return false
  end
  open_report_buffer(
    session,
    "ACP Capabilities " .. sanitize_filename_component(session.agent_name or "session"),
    "markdown",
    render_capability_report(session)
  )
  return true
end

local function relative_reference_for_path(session, path)
  local root = buffer_root_for_session(session)
  local normalized = vim.fn.fnamemodify(path or "", ":p")
  if root and normalized:sub(1, #root) == root then
    local rel = normalized:sub(#root + 2)
    if rel ~= "" then
      return "@" .. rel
    end
  end
  return "@" .. normalized
end

local function build_resource_items(session)
  local items = {}
  local seen = {}

  local function add_item(kind, label, path, reference)
    local ref = reference or relative_reference_for_path(session, path)
    if not ref or ref == "" or seen[ref] then
      return
    end
    seen[ref] = true
    items[#items + 1] = {
      kind = kind,
      label = label,
      path = path,
      reference = ref,
    }
  end

  local source_bufnr = session_source_bufnr(session)
  local root = buffer_root_for_session(session)
  if root and root ~= "" then
    add_item("workspace", "Project root", root, "@.")
  end

  if source_bufnr and vim.api.nvim_buf_is_valid(source_bufnr) then
    local source_path = vim.api.nvim_buf_get_name(source_bufnr)
    if source_path ~= "" then
      local mark = vim.api.nvim_buf_get_mark(source_bufnr, '"')
      add_item("buffer", "Current buffer", source_path)
      if type(mark) == "table" and mark[1] and mark[1] > 0 then
        add_item("cursor", "Current cursor location", source_path, relative_reference_for_path(session, source_path) .. ":" .. tostring(mark[1]))
      end
    end
  end

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.fn.buflisted(bufnr) == 1 then
      local path = vim.api.nvim_buf_get_name(bufnr)
      if path ~= "" then
        add_item("buffer", "Open buffer", path)
      end
    end
  end

  if source_bufnr then
    local history_path = cache_logic.get_cache_path(source_bufnr)
    if history_path and vim.fn.filereadable(history_path) == 1 then
      add_item("history", "Latest history log", history_path)
    end

    local summary_path = summary_logic.summary_path(source_bufnr)
    if summary_path and vim.fn.filereadable(summary_path) == 1 then
      add_item("summary", "Summary file", summary_path)
    end
  end

  if session.transcript_path and vim.fn.filereadable(session.transcript_path) == 1 then
    add_item("transcript", "Live ACP transcript", session.transcript_path)
  end

  table.sort(items, function(a, b)
    if a.kind == b.kind then
      return (a.path or a.reference or "") < (b.path or b.reference or "")
    end
    return a.kind < b.kind
  end)

  return items
end

local function insert_resource_reference(session, reference)
  if not reference or reference == "" then
    return false
  end

  local ok_window, window = pcall(require, "lazyagent.window")
  local scratch = ok_window
    and window
    and type(window.get_scratch_bufnr) == "function"
    and window.get_scratch_bufnr(session.agent_name)
    or nil
  if scratch and vim.api.nvim_buf_is_valid(scratch) and vim.b[scratch] and vim.b[scratch].lazyagent_agent == session.agent_name then
    local lines = vim.api.nvim_buf_get_lines(scratch, 0, -1, false)
    if #lines == 0 then
      vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { reference })
    else
      local last = lines[#lines] or ""
      local joiner = last:match("%S$") and " " or ""
      lines[#lines] = last .. joiner .. reference
      vim.api.nvim_buf_set_lines(scratch, 0, -1, false, lines)
    end
    vim.notify("LazyAgentACP: inserted resource reference into scratch: " .. reference, vim.log.levels.INFO)
    return true
  end

  pcall(vim.fn.setreg, '"', reference)
  pcall(vim.fn.setreg, "+", reference)
  append_block(session, "System", "Copied ACP resource reference to register:\n" .. reference)
  return false
end

local function show_resource_browser_for_session(session)
  if not session then
    return false
  end

  local items = build_resource_items(session)
  if #items == 0 then
    append_block(session, "System", "No ACP resource references are available for this session yet.")
    return false
  end

  vim.ui.select(items, {
    prompt = "Choose ACP resource:",
    format_item = function(item)
      return string.format("%s [%s] → %s", item.label, item.kind, item.reference)
    end,
  }, function(choice)
    if not choice or not choice.reference then
      return
    end
    insert_resource_reference(session, choice.reference)
  end)

  return true
end

local function render_permission_preview(tool)
  if type(tool) ~= "table" then
    return ""
  end

  local lines = {}
  local paths = extract_tool_paths(tool)
  if #paths > 0 then
    lines[#lines + 1] = "Targets:"
    for _, path in ipairs(paths) do
      lines[#lines + 1] = "- " .. path
    end
  end

  for _, item in ipairs(tool.content or {}) do
    if type(item) == "table" and item.type == "diff" then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "Diff preview: " .. tostring(item.path or "file")
      lines[#lines + 1] = "--- before"
      local before_lines = vim.split(item.oldText or "", "\n", { plain = true })
      for idx = 1, math.min(#before_lines, 6) do
        lines[#lines + 1] = before_lines[idx]
      end
      if #before_lines > 6 then
        lines[#lines + 1] = "... (truncated)"
      end
      lines[#lines + 1] = "+++ after"
      local after_lines = vim.split(item.newText or "", "\n", { plain = true })
      for idx = 1, math.min(#after_lines, 6) do
        lines[#lines + 1] = after_lines[idx]
      end
      if #after_lines > 6 then
        lines[#lines + 1] = "... (truncated)"
      end
    elseif type(item) == "table" and item.type == "content" and type(item.content) == "table" then
      local uri = item.content.uri or (type(item.content.resource) == "table" and item.content.resource.uri) or nil
      if uri and uri ~= "" then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Resource: " .. tostring(uri)
      end
    end
  end

  if #lines == 0 then
    local summary = summarize_tool(tool)
    if summary ~= "" then
      lines[#lines + 1] = summary
    end
  end

  return table.concat(lines, "\n")
end

local function handle_local_slash_command(session, prompt)
  local command, args = local_commands.parse(prompt)
  if not command or args ~= "" then
    return false
  end

  if session_has_available_command(session, command.name) then
    return false
  end

  if not local_commands.is_available(command.name, session) then
    append_block(session, "System", local_commands.unavailable_reason(command.name, session) or "ACP command unavailable.")
    return true
  end

  if command.name == "model" then
    show_config_picker_for_session(session, "model")
    return true
  end

  if command.name == "mode" then
    show_config_picker_for_session(session, "mode")
    return true
  end

  if command.name == "config" then
    show_config_picker_for_session(session, nil)
    return true
  end

  if command.name == "resources" then
    show_resource_browser_for_session(session)
    return true
  end

  if command.name == "capabilities" then
    show_capabilities_for_session(session)
    return true
  end

  if command.name == "new" then
    append_block(session, "System", "Restarting ACP session...")
    vim.schedule(function()
      require("lazyagent.logic.session").restart_session(session.agent_name)
    end)
    return true
  end

  return false
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

local function maybe_call_mcp_tool(name, params)
  local payload = params or {}

  if name == "notify_start" then
    pcall(function()
      require("lazyagent.mcp.tools").call("notify_start", payload)
    end)
    return
  end

  if name == "notify_done" then
    pcall(function()
      require("lazyagent.mcp.tools").call("notify_done", payload)
    end)
    return
  end

  if name == "notify_waiting" then
    pcall(function()
      require("lazyagent.mcp.tools").call("notify_waiting", payload)
    end)
    return
  end

  if name == "open_last_changed" then
    pcall(function()
      require("lazyagent.mcp.tools").call("open_last_changed", payload)
    end)
    return
  end
end

local function maybe_sync_acp_edit_targets(session, tool)
  local cwd = session and (session.root_dir or session.cwd) or vim.fn.getcwd()
  local content = type(tool and tool.content) == "table" and tool.content or {}
  local diff_by_path = {}

  for _, item in ipairs(content) do
    if type(item) == "table" and item.type == "diff" then
      local path = normalize_tool_path(item.path or item.filePath, cwd)
      if path and not diff_by_path[path] then
        diff_by_path[path] = item
      end
    end
  end

  local seen = {}
  for _, raw_path in ipairs(extract_tool_paths(tool)) do
    local path = normalize_tool_path(raw_path, cwd)
    if path and not seen[path] then
      seen[path] = true
      local item = diff_by_path[path] or {}
      maybe_call_mcp_tool("open_last_changed", {
        agent_name = session and session.agent_name or nil,
        cwd = cwd,
        path = path,
        oldText = item.oldText or item.old_text,
        newText = item.newText or item.new_text,
      })
    end
  end
end

buffer_root_for_session = function(session)
  if session.root_dir and session.root_dir ~= "" then
    return session.root_dir
  end
  return session.cwd or vim.fn.getcwd()
end

local function is_reference_boundary(prev_char)
  return prev_char == ""
    or prev_char:match("[%s%(%)%[%]{}<>\"'`,;]")
end

local function resolve_reference(token, session)
  local trailing = token:match("[,%.;%)%]%}]+$") or ""
  local core = trailing ~= "" and token:sub(1, #token - #trailing) or token
  if core == "" then return nil end

  local path_part = core
  local line_start, line_end, column

  local matched_path, a, b = core:match("^(.-):(%d+)%-(%d+)$")
  if matched_path then
    path_part = matched_path
    line_start = tonumber(a)
    line_end = tonumber(b)
  else
    matched_path, a, b = core:match("^(.-):(%d+):(%d+)$")
    if matched_path then
      path_part = matched_path
      line_start = tonumber(a)
      line_end = tonumber(a)
      column = tonumber(b)
    else
      matched_path, a = core:match("^(.-):(%d+)$")
      if matched_path then
        path_part = matched_path
        line_start = tonumber(a)
        line_end = tonumber(a)
      end
    end
  end

  if not path_part or path_part == "" then return nil end

  local root = buffer_root_for_session(session)
  local candidates = {}
  if path_part:match("^/") then
    table.insert(candidates, path_part)
  else
    table.insert(candidates, root .. "/" .. path_part)
    table.insert(candidates, (session.cwd or vim.fn.getcwd()) .. "/" .. path_part)
  end

  local abs_path
  local is_directory = false
  local lines
  for _, candidate in ipairs(candidates) do
    local expanded = vim.fn.fnamemodify(candidate, ":p")
    if vim.fn.isdirectory(expanded) == 1 then
      abs_path = expanded
      is_directory = true
      break
    end
    lines = read_path_lines(expanded)
    if lines then
      abs_path = expanded
      break
    end
  end

  if not abs_path then
    return nil
  end

  local note = nil
  local display = path_part
  if line_start and line_end then
    if line_end < line_start then
      line_start, line_end = line_end, line_start
    end
    if line_start == line_end and column then
      note = string.format("Context from %s at line %d, column %d:", display, line_start, column)
    elseif line_start == line_end then
      note = string.format("Context from %s line %d:", display, line_start)
    else
      note = string.format("Context from %s lines %d-%d:", display, line_start, line_end)
    end
  end

  local block
  if is_directory then
    block = {
      type = "resource_link",
      uri = file_uri(abs_path),
      name = vim.fn.fnamemodify(abs_path, ":t"),
      title = display,
    }
  else
    local content_lines = lines or {}
    if line_start and line_end then
      local start_idx = math.max(1, line_start)
      local end_idx = math.max(start_idx, line_end)
      local slice = {}
      for idx = start_idx, math.min(#content_lines, end_idx) do
        table.insert(slice, content_lines[idx])
      end
      content_lines = slice
    end
    local content = table.concat(content_lines, "\n")
    if session.prompt_supports_embedded_context then
      block = {
        type = "resource",
        resource = {
          uri = file_uri(abs_path),
          mimeType = "text/plain",
          text = content,
        },
      }
    else
      block = {
        type = "resource_link",
        uri = file_uri(abs_path),
        name = vim.fn.fnamemodify(abs_path, ":t"),
        title = display,
        mimeType = "text/plain",
      }
    end
  end

  return {
    block = block,
    note = note,
    trailing = trailing,
  }
end

local function push_text_block(blocks, text)
  if not text or text == "" then return end
  table.insert(blocks, {
    type = "text",
    text = text,
  })
end

local function build_prompt_blocks(session, text)
  local blocks = {}
  local cursor = 1
  while true do
    local start_idx, end_idx, token = text:find("@(%S+)", cursor)
    if not start_idx then break end

    local prev_char = start_idx == 1 and "" or text:sub(start_idx - 1, start_idx - 1)
    local ref = nil
    if is_reference_boundary(prev_char) then
      ref = resolve_reference(token, session)
    end

    if not ref then
      cursor = end_idx + 1
    else
      push_text_block(blocks, text:sub(cursor, start_idx - 1))
      if ref.note then
        push_text_block(blocks, ref.note)
      end
      table.insert(blocks, ref.block)
      if ref.trailing and ref.trailing ~= "" then
        push_text_block(blocks, ref.trailing)
      end
      cursor = end_idx + 1
    end
  end

  push_text_block(blocks, text:sub(cursor))
  if #blocks == 0 then
    push_text_block(blocks, text)
  end
  return blocks
end

local function next_terminal_id()
  terminal_seq = terminal_seq + 1
  return "lazyagent-term-" .. tostring(terminal_seq)
end

local function make_env_map(env_list)
  local env = vim.fn.environ()
  for _, entry in ipairs(env_list or {}) do
    if type(entry) == "table" and entry.name and entry.value ~= nil then
      env[entry.name] = tostring(entry.value)
    end
  end
  return env
end

local function append_terminal_output(session, terminal_id, data)
  if not data then return end
  local text = type(data) == "table" and table.concat(vim.tbl_filter(function(item)
    return item and item ~= ""
  end, data), "\n") or tostring(data)
  if text == "" then return end
  append_stream_chunk(session, "terminal:" .. terminal_id, "Terminal " .. terminal_id, text)
  if not text:match("\n$") then
    write_session_transcript(session, "\n")
  end
end

local function create_terminal(session, params, done)
  local terminal_id = next_terminal_id()
  local output_limit = tonumber(params.outputByteLimit) or 1024 * 1024
  local cwd = params.cwd or session.cwd
  local command = params.command
  if not command or command == "" then
    done(nil, { code = -32602, message = "terminal/create requires command" })
    return
  end

  local argv = { command }
  for _, arg in ipairs(params.args or {}) do
    table.insert(argv, tostring(arg))
  end

  local terminal = {
    id = terminal_id,
    output_limit = output_limit,
    output = "",
    truncated = false,
    exit_status = nil,
    waiters = {},
    job_id = nil,
  }
  session.terminals[terminal_id] = terminal

  local function append_output(data)
    if not data then return end
    local parts = {}
    for _, chunk in ipairs(data) do
      if chunk and chunk ~= "" then
        table.insert(parts, chunk)
      end
    end
    if #parts == 0 then return end
    local text = table.concat(parts, "\n")
    if terminal.output ~= "" and not terminal.output:match("\n$") then
      terminal.output = terminal.output .. "\n"
    end
    terminal.output = terminal.output .. text
    terminal.output, terminal.truncated = clamp_utf8_from_end(terminal.output, terminal.output_limit)
    append_terminal_output(session, terminal_id, text)
  end

  local job_id = vim.fn.jobstart(argv, {
    cwd = cwd,
    env = make_env_map(params.env or {}),
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      vim.schedule(function()
        append_output(data)
      end)
    end,
    on_stderr = function(_, data)
      vim.schedule(function()
        append_output(data)
      end)
    end,
    on_exit = function(_, code, signal)
      vim.schedule(function()
        terminal.exit_status = {
          exitCode = code,
          signal = signal == 0 and vim.NIL or signal,
        }
        close_stream(session)
        for _, waiter in ipairs(terminal.waiters) do
          pcall(waiter, {
            exitCode = code,
            signal = signal == 0 and vim.NIL or signal,
          })
        end
        terminal.waiters = {}
      end)
    end,
  })

  if job_id <= 0 then
    session.terminals[terminal_id] = nil
    done(nil, {
      code = -32000,
      message = "Failed to start terminal command: " .. command,
    })
    return
  end

  terminal.job_id = job_id
  done({ terminalId = terminal_id })
end

local function terminal_output(session, params)
  local terminal = session.terminals[params.terminalId or ""]
  if not terminal then
    return nil, { code = -32602, message = "Unknown terminalId: " .. tostring(params.terminalId) }
  end

  local result = {
    output = terminal.output,
    truncated = terminal.truncated == true,
  }
  if terminal.exit_status then
    result.exitStatus = terminal.exit_status
  end
  return result
end

local function terminal_wait_for_exit(session, params, done)
  local terminal = session.terminals[params.terminalId or ""]
  if not terminal then
    done(nil, { code = -32602, message = "Unknown terminalId: " .. tostring(params.terminalId) })
    return
  end

  if terminal.exit_status then
    done({
      exitCode = terminal.exit_status.exitCode,
      signal = terminal.exit_status.signal,
    })
    return
  end

  table.insert(terminal.waiters, done)
end

local function terminal_kill(session, params)
  local terminal = session.terminals[params.terminalId or ""]
  if not terminal then
    return nil, { code = -32602, message = "Unknown terminalId: " .. tostring(params.terminalId) }
  end
  if terminal.job_id then
    pcall(vim.fn.jobstop, terminal.job_id)
  end
  return vim.NIL
end

local function terminal_release(session, params)
  local terminal = session.terminals[params.terminalId or ""]
  if not terminal then
    return vim.NIL
  end
  if terminal.job_id and not terminal.exit_status then
    pcall(vim.fn.jobstop, terminal.job_id)
  end
  session.terminals[params.terminalId] = nil
  return vim.NIL
end

resolve_permission_option = function(options, preferred_kind)
  if type(options) ~= "table" then return nil end
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
  return nil
end

local function resolve_best_allow_option(options)
  return resolve_permission_option(options, "allow_always")
    or resolve_permission_option(options, "allow_once")
end

local function handle_permission_request(session, params, done)
  local latest_cfg = acp_logic.resolve_config(session.agent_cfg or {})
  session.auto_permission = latest_cfg.auto_permission
  session.permission_rules = vim.deepcopy(latest_cfg.permission_rules or {})
  local tool = merge_tool_update(session, params.toolCall or {})
  append_block(session, tool_heading(tool), tool.title or tool.toolCallId or "Permission requested", {
    kind = "tool",
    title = tool.title or tool.toolCallId or "Permission requested",
    summary = tool.title or tool.toolCallId or "Permission requested",
    toolCallId = tool.toolCallId,
    status = tool.status,
    path = (extract_tool_paths(tool) or {})[1],
  })
  maybe_call_mcp_tool("notify_waiting", {
    agent_name = session.agent_name,
    message = "Permission",
  })

  local rule_resolution = resolve_permission_rule(session, tool, params.options or {})
  local rule_matched = rule_resolution and rule_resolution.matched == true
  if rule_matched and rule_resolution.option then
    append_block(
      session,
      "System",
      string.format(
        "ACP permission rule `%s` matched and selected `%s`.",
        rule_resolution.label or "rule",
        rule_resolution.action or rule_resolution.option.kind or "option"
      )
    )
    pcall(function()
      require("lazyagent.logic.status").start_monitor(session.agent_name)
    end)
    done({
      outcome = "selected",
      optionId = rule_resolution.option.optionId,
    })
    return
  elseif rule_matched then
    append_block(
      session,
      "System",
      string.format("ACP permission rule `%s` matched and requires manual confirmation.", rule_resolution.label or "rule")
    )
  end

  local preferred = session.auto_permission
  if not rule_matched and not preferred and session.agent_cfg and session.agent_cfg.yolo then
    preferred = "allow_once"
  end

  local auto = nil
  if not rule_matched then
    auto = resolve_permission_option(params.options or {}, preferred)
  end
  if not auto and not rule_matched and preferred == "allow_always" then
    auto = resolve_best_allow_option(params.options or {})
  end

  -- Auto-allow write/edit tools when a previous auto-fix was requested
  if not auto and not rule_matched then
    local ok, state_mod = pcall(function() return require("lazyagent.logic.state") end)
    if ok and state_mod and state_mod._fix_requested == true then
      local is_edit_tool = false
      if type(tool) == "table" then
        local kind = tostring(tool.kind or "")
        local tname = tostring(tool.toolName or tool.name or tool.title or ""):lower()
        if kind == "edit" or tname:match("write_text_file") or tname:match("write") then
          is_edit_tool = true
        end
      end
      if is_edit_tool then
        local allow_opt = resolve_permission_option(params.options or {}, "allow_once") or resolve_best_allow_option(params.options or {})
        if allow_opt then
          pcall(function()
            require("lazyagent.logic.status").start_monitor(session.agent_name)
          end)
          done({ outcome = "selected", optionId = allow_opt.optionId })
          return
        end
      end
    end
  end

  if auto then
    pcall(function()
      require("lazyagent.logic.status").start_monitor(session.agent_name)
    end)
    done({
      outcome = "selected",
      optionId = auto.optionId,
    })
    return
  end

  local preview = render_permission_preview(tool)
  if preview ~= "" then
    append_block(session, "Edited Preview", preview)
  end

  local labels = {}
  for _, option in ipairs(params.options or {}) do
    table.insert(labels, string.format("%s [%s]", option.name or option.optionId or "Option", option.kind or "option"))
  end

  vim.schedule(function()
    vim.ui.select(labels, {
      prompt = string.format("%s permission: %s", session.agent_name, tool.title or tool.toolCallId or "tool"),
    }, function(_, idx)
      local selected = idx and params.options and params.options[idx] or nil
      if not selected then
        selected = resolve_permission_option(params.options or {}, "reject_once")
      end
      if selected then
        pcall(function()
          require("lazyagent.logic.status").start_monitor(session.agent_name)
        end)
        done({
          outcome = "selected",
          optionId = selected.optionId,
        })
      else
        done({ outcome = "cancelled" })
      end
    end)
  end)
end

local function read_text_file(_, params)
  local path = params.path
  if not path or path == "" then
    return nil, { code = -32602, message = "fs/read_text_file requires path" }
  end

  local abs = vim.fn.fnamemodify(path, ":p")
  local lines = read_path_lines(abs)
  if not lines then
    return nil, { code = -32602, message = "File not found: " .. abs }
  end

  local start_line = tonumber(params.line) or 1
  local limit = tonumber(params.limit)
  local start_idx = math.max(1, start_line)
  local end_idx = #lines
  if limit and limit >= 0 then
    end_idx = math.min(#lines, start_idx + limit - 1)
  end

  local slice = {}
  for idx = start_idx, end_idx do
    table.insert(slice, lines[idx])
  end

  return {
    content = table.concat(slice, "\n"),
  }
end

local function write_text_file(session, params)
  local path = params.path
  if not path or path == "" then
    return nil, { code = -32602, message = "fs/write_text_file requires path" }
  end

  local abs = vim.fn.fnamemodify(path, ":p")
  local before_lines = read_path_lines(abs) or {}
  local before_text = table.concat(before_lines, "\n")
  local content = normalize_text(params.content or "")
  ensure_parent_dir(abs)

  local ok_watch, watch = pcall(require, "lazyagent.watch")
  if ok_watch and watch and type(watch.suspend) == "function" then
    pcall(watch.suspend, abs, 1500)
  end

  local lines = vim.split(content, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines, #lines)
  end

  local _, bufnr = read_buffer_lines_for_path(abs)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, lines)
    pcall(function() vim.bo[bufnr].modified = false end)
  end

  local file, err = io.open(abs, "w")
  if not file then
    return nil, { code = -32000, message = tostring(err) }
  end
  file:write(content)
  file:close()

  append_block(session, "Edited " .. vim.fn.fnamemodify(abs, ":."), "Updated via ACP fs/write_text_file")
  maybe_call_mcp_tool("open_last_changed", {
    agent_name = session and session.agent_name or nil,
    cwd = session and (session.root_dir or session.cwd) or vim.fn.getcwd(),
    path = abs,
    oldText = before_text,
    newText = content,
  })
  return vim.NIL
end

local function on_client_update(session, params)
  if not params or not params.update then return end
  local update = params.update
  local kind = update.sessionUpdate

  if kind == "agent_message_chunk" then
    local text = render_content(update.content)
    append_stream_chunk(session, "assistant", assistant_heading_label(session), text, {
      kind = "assistant",
    })
    return
  end

  if kind == "agent_thought_chunk" then
    append_stream_chunk(session, "thought", "Thinking", render_content(update.content))
    return
  end

  if kind == "user_message_chunk" then
    append_stream_chunk(session, "user", "User", render_content(update.content))
    return
  end

  if kind == "plan" and type(update.entries) == "table" then
    local lines = {}
    for _, entry in ipairs(update.entries) do
      if type(entry) == "table" then
        table.insert(lines, string.format("- [%s] %s", entry.status or "pending", entry.content or ""))
      end
    end
    append_block(session, "Plan", table.concat(lines, "\n"))
    return
  end

  if kind == "available_commands_update" then
    session.available_commands = normalize_available_commands(update.availableCommands)
    sync_runtime_session(session)
    return
  end

  if kind == "config_option_update" then
    session.config_options = vim.deepcopy((session.client and session.client.config_options) or update.configOptions or {})
    sync_runtime_session(session)
    return
  end

  if kind == "current_mode_update" or kind == "current_model_update" then
    if kind == "current_mode_update" and type(session.mode_catalog) == "table" then
      session.mode_catalog.currentModeId = update.modeId or update.currentModeId or update.currentMode or session.mode_catalog.currentModeId
    elseif kind == "current_model_update" and type(session.model_catalog) == "table" then
      session.model_catalog.currentModelId = update.modelId or update.currentModelId or update.currentModel or session.model_catalog.currentModelId
    end
    session.config_options = vim.deepcopy((session.client and session.client.config_options) or session.config_options or {})
    sync_runtime_session(session)
    return
  end

  if kind == "session_info_update" then
    update_session_info(session, update)
    sync_runtime_session(session)
    return
  end

  if kind == "usage_update" then
    -- Merge usage info into model catalog so UI can display context/usage
    local model_id = update.modelId or update.currentModelId or (update.model and update.model.modelId) or nil
    if type(session.model_catalog) == "table" and type(session.model_catalog.availableModels) == "table" then
      for _, m in ipairs(session.model_catalog.availableModels) do
        if type(m) == "table" and (not model_id or m.modelId == model_id) then
          m._meta = m._meta or {}
          if type(update.usage) == "table" then
            m._meta.usage = vim.deepcopy(update.usage)
            local used = nil
            local total = nil
            if update.usage.promptTokens or update.usage.completionTokens then
              local p = tonumber(update.usage.promptTokens) or 0
              local c = tonumber(update.usage.completionTokens) or 0
              used = p + c
            elseif update.usage.usedTokens then
              used = tonumber(update.usage.usedTokens)
            end
            total = tonumber(update.usage.totalTokens) or tonumber(update.usage.contextSize) or tonumber(m._meta.contextSize) or tonumber(m.contextSize)
            if used and total then
              m._meta.token_usage_used = used
              m._meta.token_usage_total = total
            end
          end
          if type(update.model) == "table" and type(update.model._meta) == "table" then
            for k, v in pairs(update.model._meta) do
              m._meta[k] = v
            end
          end
          if update.copilotUsage then
            m._meta.copilotUsage = tostring(update.copilotUsage)
          end
        end
      end
    end
    update_usage_stats(session, update, model_id)
    sync_runtime_session(session)
    return
  end

  if kind == "tool_call" or kind == "tool_call_update" then
    local tool = merge_tool_update(session, update)
    local title = tool.title or tool.toolCallId or "tool"
    local body = render_tool_content(tool.content)
    if body == "" then
      body = render_tool_raw_output(tool.rawOutput)
    end
    local hide_pending = state and state.opts and state.opts.acp and state.opts.acp.hide_pending_messages == true
    local is_terminal = tool_update_is_terminal(tool)
    if not (hide_pending and not is_terminal) then
      if body ~= "" then
        append_block(session, tool_heading(tool), summarize_tool_block(tool, title, body), {
          kind = "tool",
          title = title,
          summary = summarize_tool_block(tool, title, body),
          toolCallId = tool.toolCallId,
          status = tool.status,
          path = (extract_tool_paths(tool) or {})[1],
        })
      else
        append_block(session, tool_heading(tool), title, {
          kind = "tool",
          title = title,
          summary = title,
          toolCallId = tool.toolCallId,
          status = tool.status,
          path = (extract_tool_paths(tool) or {})[1],
        })
      end
    end
    if is_terminal then
      if session.ephemeral ~= true and tool.kind == "edit" then
        util.fire_event("EditDone", { agent_name = session.agent_name, tool = tool })
      end
      if session.ephemeral ~= true then
        maybe_sync_acp_edit_targets(session, tool)
      end

      session.tool_calls[tool.toolCallId] = nil
    end
    return
  end
end

local function on_client_exit(session, code, signal, stderr_text)
  if session and session.ephemeral == true then
    return
  end
  if session and session.closing_intentionally == true then
    session.ready = false
    session.failed = false
    close_stream(session)
    return
  end
  session.ready = false
  session.failed = true
  close_stream(session)
  sync_runtime_session(session)
  local message = string.format("ACP agent exited (code=%s signal=%s)", tostring(code), tostring(signal))
  if stderr_text and stderr_text ~= "" then
    message = message .. "\n" .. stderr_text
  end
  append_block(session, "System", message)
  pcall(function()
    require("lazyagent.logic.status").set_waiting(session.agent_name, "Disconnected")
  end)
end

local function list_all_sessions_for_client(client, params, on_done, collected)
  collected = collected or {}
  client:list_sessions(params, function(result, err)
    if err then
      on_done(nil, err)
      return
    end

    result = type(result) == "table" and result or {}
    for _, item in ipairs(result.sessions or {}) do
      if type(item) == "table" and item.sessionId and item.sessionId ~= "" then
        collected[#collected + 1] = normalize_session_info(item.sessionId, item)
      end
    end

    if result.nextCursor and result.nextCursor ~= "" then
      local next_params = vim.tbl_extend("force", params or {}, {
        cursor = result.nextCursor,
      })
      list_all_sessions_for_client(client, next_params, on_done, collected)
      return
    end

    on_done(collected, nil)
  end)
end

local function create_ephemeral_session(base_session)
  local transcript_path = build_transcript_path((base_session.agent_name or "acp") .. "-native", 0)
  return {
    ephemeral = true,
    runtime_sync_disabled = true,
    pane_id = "",
    agent_name = base_session.agent_name,
    agent_cfg = vim.deepcopy(base_session.agent_cfg or {}),
    transcript_path = transcript_path,
    transcript_has_content = false,
    current_stream_key = nil,
    current_stream_heading = nil,
    current_stream_at_line_start = nil,
    prompt_queue = {},
    tool_calls = {},
    terminals = {},
    available_commands = {},
    config_options = {},
    on_ready_actions = {},
    permission_rules = vim.deepcopy(base_session.permission_rules or {}),
    auto_switch = vim.deepcopy(base_session.auto_switch or {}),
    manual_config_overrides = {},
    auto_switch_state = {},
    conversation_timeline = {},
    conversation_timeline_index = {},
    conversation_next_item_id = 0,
    tool_timeline = {},
    tool_timeline_index = {},
    ready = false,
    failed = false,
    busy = false,
    preparing_prompt = false,
    command = base_session.command,
    env = vim.deepcopy(base_session.env or {}),
    cwd = base_session.cwd or vim.fn.getcwd(),
    root_dir = base_session.root_dir,
    mcp_url = base_session.mcp_url,
    auto_permission = base_session.auto_permission,
    default_mode = base_session.default_mode,
    initial_model = base_session.initial_model,
    table_layout = base_session.table_layout,
    footer_animation = false,
    buffer_background = base_session.buffer_background,
    buffer_inactive_background = base_session.buffer_inactive_background,
    transcript_max_lines = base_session.transcript_max_lines,
    transcript_compaction = vim.deepcopy(base_session.transcript_compaction or {}),
    initial_config_applied = true,
    session_info = {},
    usage_stats = {},
  }
end

local function stop_ephemeral_client(session, callback)
  local client = session and session.client or nil
  if not client then
    if callback then
      callback()
    end
    return
  end

  local done = function()
    client:stop()
    if callback then
      callback()
    end
  end

  if client:supports_session_close() and client.session_id and client.session_id ~= "" then
    client:close_session(client.session_id, function()
      done()
    end)
    return
  end

  done()
end

local function capture_native_session_for_session(session, native_session, on_done)
  local temp_session = create_ephemeral_session(session)
  local finished = false

  local function finish(snapshot, err)
    if finished then
      return
    end
    finished = true
    stop_ephemeral_client(temp_session, function()
      vim.schedule(function()
        on_done(snapshot, err)
      end)
    end)
  end

  temp_session.client = ACPClient.new({
    command = temp_session.command,
    cwd = temp_session.cwd,
    env = temp_session.env,
    mcp_url = temp_session.mcp_url,
    client_info = {
      name = "lazyagent",
      title = "lazyagent.nvim",
      version = "0.1.0",
    },
    handlers = {},
    on_update = function(params)
      on_client_update(temp_session, params)
    end,
    on_exit = function(code, signal, stderr_text)
      on_client_exit(temp_session, code, signal, stderr_text)
    end,
  })

  temp_session.client:start(function(client, err)
    if err then
      finish(nil, err)
      return
    end

    client:load_session(native_session.sessionId, function(_, load_err)
      if load_err then
        finish(nil, load_err)
        return
      end

      temp_session.client = client
      temp_session.ready = true
      temp_session.failed = false
      temp_session.session_id = client.session_id
      update_session_info(temp_session, native_session)
      update_session_info(temp_session, {
        sessionId = client.session_id,
        cwd = temp_session.cwd,
      })

      local transcript = ""
      if vim.fn.filereadable(temp_session.transcript_path) == 1 then
        local ok, lines = pcall(vim.fn.readfile, temp_session.transcript_path)
        if ok and lines then
          transcript = table.concat(lines, "\n")
        end
      end

      local transcript_lines = transcript ~= "" and vim.split(transcript, "\n", { plain = true }) or {}
      if #transcript_lines > 0 and transcript_lines[#transcript_lines] == "" then
        table.remove(transcript_lines, #transcript_lines)
      end

      finish({
        provider_from = session.agent_name,
        carryover_label = string.format(
          "an ACP provider session%s",
          native_session.title and native_session.title ~= "" and (" (" .. native_session.title .. ")") or ""
        ),
        transcript_lines = transcript_lines,
        transcript_path = temp_session.transcript_path,
        conversation_timeline = vim.deepcopy(temp_session.conversation_timeline or {}),
        tool_timeline = vim.deepcopy(temp_session.tool_timeline or {}),
        session_info = vim.deepcopy(temp_session.session_info or {}),
      }, nil)
    end)
  end, {
    create_session = false,
  })
end

local function create_backend(default_view)
  local backend = {}

  local function session_view(session)
    return (session and session.view) or default_view
  end

  local function start_client(session)
    local handlers = {
      request_permission = function(params, done)
        handle_permission_request(session, params, done)
      end,
      read_text_file = function(params)
        return read_text_file(session, params)
      end,
      write_text_file = function(params)
        return write_text_file(session, params)
      end,
      create_terminal = function(params, done)
        create_terminal(session, params, done)
      end,
      terminal_output = function(params)
        return terminal_output(session, params)
      end,
      terminal_wait_for_exit = function(params, done)
        terminal_wait_for_exit(session, params, done)
      end,
      terminal_kill = function(params)
        return terminal_kill(session, params)
      end,
      terminal_release = function(params)
        return terminal_release(session, params)
      end,
    }

    session.client = ACPClient.new({
      command = session.command,
      cwd = session.cwd,
      env = session.env,
      mcp_url = session.mcp_url,
      client_info = {
        name = "lazyagent",
        title = "lazyagent.nvim",
        version = "0.1.0",
      },
      handlers = handlers,
      on_update = function(params)
        on_client_update(session, params)
      end,
      on_exit = function(code, signal, stderr_text)
        on_client_exit(session, code, signal, stderr_text)
      end,
    })

    session.client:start(function(client, err, session_result)
      if err then
        session.failed = true
        session.ready = false
        sync_runtime_session(session)
        append_block(session, "System", "Failed to start ACP session: " .. (err.message or tostring(err)))
        pcall(function()
          require("lazyagent.logic.status").set_waiting(session.agent_name, "ACP error")
        end)
        vim.schedule(function()
          vim.notify("LazyAgent ACP: " .. (err.message or tostring(err)), vim.log.levels.ERROR)
        end)
        return
      end

      session.client = client
      session.ready = true
      session.failed = false
      session.session_id = client.session_id
      update_session_info(session, {
        sessionId = client.session_id,
        cwd = session.cwd,
      })
      session.config_options = vim.deepcopy(client.config_options or (session_result and session_result.configOptions) or {})
      session.agent_info = vim.deepcopy(client.agent_info or {})
      session.agent_capabilities = vim.deepcopy(client.agent_capabilities or {})
      session.model_catalog = vim.deepcopy((session_result and session_result.models) or {})
      session.mode_catalog = vim.deepcopy((session_result and session_result.modes) or {})
      local prompt_caps = client.agent_capabilities and client.agent_capabilities.promptCapabilities or {}
      session.prompt_supports_embedded_context = prompt_caps and prompt_caps.embeddedContext == true
      session.mcp_server_count = 0
      sync_runtime_session(session)
      local agent_name = client.agent_info and (client.agent_info.title or client.agent_info.name) or session.agent_name
      local message = string.format("ACP session ready: %s", agent_name)
      if session_result and session_result.sessionId then
        message = message .. "\nSession ID: " .. session_result.sessionId
      end
      append_block(session, "System", message)
      apply_initial_session_config(session, function()
        local on_ready_actions = session.on_ready_actions or {}
        session.on_ready_actions = {}
        for _, callback in ipairs(on_ready_actions) do
          vim.schedule(function()
            pcall(callback)
          end)
        end
        if #session.prompt_queue > 0 then
          vim.schedule(function()
            backend._drain_prompt_queue(session.pane_id)
          end)
        end
      end)
    end)
  end

  function backend._drain_prompt_queue(pane_id)
    local session = get_session(pane_id)
    if not session or session.failed or session.busy or session.preparing_prompt or not session.ready or not session.client then
      return false
    end

    local prompt = table.remove(session.prompt_queue, 1)
    if not prompt then
      return false
    end

    session.preparing_prompt = true
    maybe_apply_auto_switch(session, prompt, function()
      session.preparing_prompt = false
      session.busy = true
      maybe_call_mcp_tool("notify_start", { agent_name = session.agent_name })
      note_unadvertised_slash_command(session, prompt)
      append_block(session, "User", prompt)

      local blocks = {}
      if session.pending_switch_history then
        vim.list_extend(blocks, build_switch_history_blocks(session, session.pending_switch_history))
      end
      vim.list_extend(blocks, build_prompt_blocks(session, prompt))
      session.client:send_prompt(blocks, function(result, err)
        session.busy = false
        close_stream(session)

        if err then
          append_block(session, "Error", err.message or tostring(err))
          pcall(function()
            require("lazyagent.logic.status").set_waiting(session.agent_name, "ACP error")
          end)
          session.prompt_queue = {}
          return
        end

        if session.pending_switch_history then
          clear_pending_switch_history(session)
        end

        local stop_reason = result and result.stopReason or nil
        if stop_reason == "tool_call" then
          pcall(function()
            require("lazyagent.logic.status").start_monitor(session.agent_name)
          end)
          return
        end

        if stop_reason and stop_reason ~= "end_turn" then
          append_block(session, "System", "Turn finished with stopReason: " .. tostring(stop_reason))
        end

                util.fire_event("AssistantResponse", { agent_name = session.agent_name, result = result })
        util.fire_event("TurnDone", { agent_name = session.agent_name, result = result })
        maybe_call_mcp_tool("notify_done", { agent_name = session.agent_name })

        if #session.prompt_queue > 0 then
          backend._drain_prompt_queue(pane_id)
        end
      end)
    end)

    return true
  end

  function backend.configure_pane(pane_id, opts)
    local session = get_session(pane_id)
    local view = session_view(session)
    if view and type(view.configure_pane) == "function" then
      return view.configure_pane(pane_id, opts, session)
    end
    return false
  end

  function backend.clear_pane_config(pane_id)
    local session = get_session(pane_id)
    local view = session_view(session)
    if view and type(view.clear_pane_config) == "function" then
      return view.clear_pane_config(pane_id, session)
    end
    return false
  end

  function backend.split(_, size, is_vertical, on_split_or_opts)
    local on_split = on_split_or_opts
    local opts = {}
    if type(on_split_or_opts) == "table" then
      opts = on_split_or_opts
      on_split = opts.on_split
    end

    local acp = opts.acp or {}
    if not acp.agent_name or not acp.command then
      if on_split then
        vim.schedule(function() on_split(nil) end)
      end
      return
    end

    local view = default_view
    if not view or type(view.create_pane) ~= "function" then
      if on_split then
        vim.schedule(function() on_split(nil) end)
      end
      return
    end

    local transcript_path = build_transcript_path(acp.agent_name, acp.source_bufnr)
    local initial_text = render_section_block("System", "Connecting ACP session for " .. acp.agent_name .. "...")
    write_transcript(transcript_path, "", "w")
    write_transcript(transcript_path, initial_text, "a")

    view.create_pane({
      acp = acp,
      opts = opts,
      size = size,
      is_vertical = is_vertical,
      transcript_path = transcript_path,
      initial_text = initial_text,
    }, function(pane_id, view_state)
      if not pane_id or pane_id == "" then
        if on_split then on_split(nil) end
        return
      end

      sessions[pane_id] = {
        pane_id = pane_id,
        agent_name = acp.agent_name,
        agent_cfg = acp.agent_cfg or {},
        transcript_path = transcript_path,
        transcript_has_content = true,
        current_stream_key = nil,
        current_stream_heading = nil,
        current_stream_at_line_start = nil,
        prompt_queue = {},
        tool_calls = {},
        terminals = {},
        available_commands = {},
        config_options = {},
        on_ready_actions = {},
        permission_rules = vim.deepcopy(acp.permission_rules or {}),
        auto_switch = vim.deepcopy(acp.auto_switch or {}),
        manual_config_overrides = {},
        auto_switch_state = {},
        conversation_timeline = {},
        conversation_timeline_index = {},
        conversation_next_item_id = 0,
        tool_timeline = {},
        tool_timeline_index = {},
        ready = false,
        failed = false,
        busy = false,
        preparing_prompt = false,
        command = acp.command,
        env = acp.env or {},
        cwd = acp.cwd or vim.fn.getcwd(),
        root_dir = acp.root_dir,
        mcp_url = acp.mcp_url,
        session_bootstrap = vim.deepcopy(acp.session_bootstrap),
        auto_permission = acp.auto_permission,
        default_mode = acp.default_mode,
        initial_model = acp.initial_model,
        table_layout = acp.table_layout,
        footer_animation = acp.footer_animation,
        buffer_background = acp.buffer_background,
        buffer_inactive_background = acp.buffer_inactive_background,
        transcript_max_lines = acp.transcript_max_lines,
        transcript_compaction = vim.deepcopy(acp.transcript_compaction or {}),
        initial_config_applied = false,
        session_info = {},
        usage_stats = {},
        view = view,
        view_state = view_state or {},
      }
      new_conversation_item(
        sessions[pane_id],
        "System",
        "Connecting ACP session for " .. acp.agent_name .. "..."
      )

      if type(view.on_session_created) == "function" then
        view.on_session_created(sessions[pane_id])
      end
      start_client(sessions[pane_id])
      if on_split then on_split(pane_id) end
    end)
  end

  function backend.pane_exists(pane_id)
    local session = get_session(pane_id)
    if not session then
      return false
    end
    local view = session_view(session)
    if view and type(view.pane_exists) == "function" then
      return view.pane_exists(pane_id, session)
    end
    return true
  end

  function backend.get_pane_pid(pane_id)
    local session = get_session(pane_id)
    if session and session.client and session.client.pid then
      return session.client.pid
    end
    return nil
  end

  function backend.get_runtime_snapshot(pane_id)
    local session = get_session(pane_id)
    if not session then
      return nil
    end

    return {
      pane_id = session.pane_id,
      cwd = session.cwd,
      root_dir = session.root_dir,
      transcript_path = session.transcript_path,
      footer_animation = session.footer_animation,
      buffer_background = session.buffer_background,
      buffer_inactive_background = session.buffer_inactive_background,
      transcript_max_lines = session.transcript_max_lines,
      transcript_compaction = vim.deepcopy(session.transcript_compaction or {}),
        acp_available_commands = vim.deepcopy(session.available_commands or {}),
        acp_config_options = vim.deepcopy(session.config_options or {}),
        acp_session_id = session.session_id,
        acp_session_info = vim.deepcopy(session.session_info or {}),
        acp_transcript_path = session.transcript_path,
        acp_agent_info = vim.deepcopy(session.agent_info or {}),
        acp_agent_capabilities = vim.deepcopy(session.agent_capabilities or {}),
        acp_session_capabilities = vim.deepcopy((session.agent_capabilities and session.agent_capabilities.sessionCapabilities) or {}),
        acp_model_catalog = vim.deepcopy(session.model_catalog or {}),
        acp_mode_catalog = vim.deepcopy(session.mode_catalog or {}),
        acp_usage_stats = vim.deepcopy(session.usage_stats or {}),
      acp_ready = session.ready == true,
      acp_failed = session.failed == true,
      acp_supports_embedded_context = session.prompt_supports_embedded_context == true,
      acp_mcp_server_count = session.mcp_server_count or ((session.mcp_url and session.mcp_url ~= "") and 1 or 0),
      acp_permission_rules = vim.deepcopy(session.permission_rules or {}),
      acp_auto_switch = vim.deepcopy(session.auto_switch or {}),
      acp_manual_config_overrides = vim.deepcopy(session.manual_config_overrides or {}),
      acp_tool_timeline = vim.deepcopy(session.tool_timeline or {}),
      acp_conversation_timeline = vim.deepcopy(session.conversation_timeline or {}),
      source_winid = session.view_state and session.view_state.source_winid or nil,
    }
  end

  function backend.send_keys(pane_id, keys)
    local session = get_session(pane_id)
    if not session or not keys then return false end
    if type(keys) ~= "table" then keys = { keys } end
    local literal_mode = false

    for _, key in ipairs(keys) do
      local normalized = tostring(key)
      if normalized == "--literal" then
        literal_mode = true
      elseif normalized == "C-c" or normalized == string.char(3) then
        if session.client then
          session.client:cancel()
          append_block(session, "System", "Cancellation requested")
        end
        return true
      elseif normalized == "Up" then
        if session.view and type(session.view.scroll_up) == "function" then
          return session.view.scroll_up(pane_id)
        end
        return true
      elseif normalized == "Down" then
        if session.view and type(session.view.scroll_down) == "function" then
          return session.view.scroll_down(pane_id)
        end
        return true
      elseif normalized == "Escape" then
        if session.view and type(session.view.resume_follow) == "function" then
          return session.view.resume_follow(pane_id)
        end
        return true
      elseif normalized:match("^%d$") or (literal_mode and #normalized > 0) then
        backend.paste_and_submit(pane_id, normalized, { "C-m" }, {})
        return true
      end
    end

    return true
  end

  function backend.kill_pane(pane_id)
    local session = get_session(pane_id)
    if session then
      clear_pending_switch_history(session)
      session.closing_intentionally = true
      for terminal_id, _ in pairs(session.terminals or {}) do
        pcall(terminal_release, session, { terminalId = terminal_id })
      end
      local view = session_view(session)
      if view and type(view.kill_pane) == "function" then
        view.kill_pane(pane_id, session)
      end
      sessions[pane_id] = nil
      if session.client then
        local client = session.client
        local stopped = false
        local stop_client = function()
          if stopped then
            return
          end
          stopped = true
          client:stop()
        end

        if client:supports_session_close() and session.session_id and session.session_id ~= "" then
          client:close_session(session.session_id, function()
            stop_client()
          end)
          vim.defer_fn(function()
            if client:is_connected() then
              stop_client()
            end
          end, 1000)
        else
          stop_client()
        end
      end
      return
    end

    local view = session_view(nil)
    if view and type(view.kill_pane) == "function" then
      view.kill_pane(pane_id, nil)
    end
  end

  function backend.kill_pane_sync(pane_id)
    backend.kill_pane(pane_id)
  end

  function backend.get_pane_info(pane_id, on_info)
    local session = get_session(pane_id)
    local view = session_view(session)
    if view and type(view.get_pane_info) == "function" then
      return view.get_pane_info(pane_id, on_info, session)
    end
    if on_info then
      vim.schedule(function()
        on_info(nil)
      end)
    end
    return false
  end

  function backend.is_busy(target_pane)
    local session = get_session(target_pane)
    if not session then
      return false
    end
    return session.busy == true
      or session.preparing_prompt == true
      or (type(session.prompt_queue) == "table" and #session.prompt_queue > 0)
  end

  function backend.restore_switch_snapshot(target_pane, snapshot)
    local session = get_session(target_pane)
    if not session then
      return false
    end
    return restore_switch_snapshot(session, snapshot)
  end

  function backend.break_pane(pane_id)
    local session = get_session(pane_id)
    local view = session_view(session)
    if view and type(view.break_pane) == "function" then
      return view.break_pane(pane_id, session)
    end
    return false
  end

  function backend.break_pane_sync(pane_id)
    local session = get_session(pane_id)
    local view = session_view(session)
    if view and type(view.break_pane_sync) == "function" then
      return view.break_pane_sync(pane_id, session)
    end
    return backend.break_pane(pane_id)
  end

  function backend.join_pane(pane_id, size, is_vertical, on_done)
    local session = get_session(pane_id)
    local view = session_view(session)
    if view and type(view.join_pane) == "function" then
      return view.join_pane(pane_id, size, is_vertical, on_done, session)
    end
    if on_done then
      vim.schedule(function()
        on_done(false)
      end)
    end
    return false
  end

  function backend.copy_mode(pane_id)
    local session = get_session(pane_id)
    local view = session_view(session)
    if view and type(view.copy_mode) == "function" then
      return view.copy_mode(pane_id, session)
    end
    return false
  end

  function backend.scroll_up(pane_id)
    local session = get_session(pane_id)
    local view = session_view(session)
    if view and type(view.scroll_up) == "function" then
      return view.scroll_up(pane_id, session)
    end
    return false
  end

  function backend.scroll_down(pane_id)
    local session = get_session(pane_id)
    local view = session_view(session)
    if view and type(view.scroll_down) == "function" then
      return view.scroll_down(pane_id, session)
    end
    return false
  end

  function backend.cleanup_if_idle()
    local view = session_view(nil)
    if view and type(view.cleanup_if_idle) == "function" then
      return view.cleanup_if_idle()
    end
    return false
  end

  function backend.paste(target_pane, opts)
    opts = opts or {}
    return backend.paste_and_submit(target_pane, opts.text or "", { "C-m" }, opts)
  end

  function backend.paste_and_submit(target_pane, text, _, _)
    local session = get_session(target_pane)
    if not session then return false end
    if session.failed then
      append_block(session, "Error", "ACP session is disconnected. Restart the agent session to continue.")
      return false
    end

    local prompt = normalize_text(text or "")
    if prompt == "" then
      return true
    end
    if prompt:match("\n$") then
      prompt = prompt:gsub("\n+$", "")
    end
    if handle_local_slash_command(session, prompt) then
      return "handled"
    end
    table.insert(session.prompt_queue, prompt)
    backend._drain_prompt_queue(target_pane)
    return true
  end

  function backend.show_config_picker(target_pane, category)
    local session = get_session(target_pane)
    if not session then
      return false
    end
    return show_config_picker_for_session(session, category)
  end

  function backend.show_command_palette(target_pane)
    local session = get_session(target_pane)
    if not session then
      return false
    end
    return show_command_palette_for_session(session, function(prompt)
      backend.paste_and_submit(target_pane, prompt, { "C-m" }, {})
    end)
  end

  function backend.show_tool_timeline(target_pane)
    local session = get_session(target_pane)
    if not session then
      return false
    end
    return show_tool_timeline_for_session(session)
  end

  function backend.show_tool_timeline_entry(target_pane, tool_call_id)
    local session = get_session(target_pane)
    local entry = session and tool_timeline_entry_for_call(session, tool_call_id) or nil
    if not entry then
      return false
    end
    open_tool_timeline_buffer(session, entry)
    return true
  end

  function backend.get_tool_timeline_entry(target_pane, tool_call_id)
    local session = get_session(target_pane)
    local entry = session and tool_timeline_entry_for_call(session, tool_call_id) or nil
    return entry and vim.deepcopy(entry) or nil
  end

  function backend.get_conversation_timeline(target_pane)
    local session = get_session(target_pane)
    return session and vim.deepcopy(session.conversation_timeline or {}) or {}
  end

  function backend.toggle_conversation_pin(target_pane, item_id, pinned)
    local session = get_session(target_pane)
    local item = session and conversation_item_for_id(session, item_id) or nil
    if not item then
      return nil
    end
    if pinned == nil then
      pinned = not item.pinned
    end
    item.pinned = pinned == true
    sync_tool_pin_state(session, item)
    if sync_runtime_live_state then
      sync_runtime_live_state(session)
    end
    return item.pinned
  end

  function backend.show_resource_browser(target_pane)
    local session = get_session(target_pane)
    if not session then
      return false
    end
    return show_resource_browser_for_session(session)
  end

  function backend.show_capabilities(target_pane)
    local session = get_session(target_pane)
    if not session then
      return false
    end
    return show_capabilities_for_session(session)
  end

  function backend.list_sessions(target_pane, on_done, opts)
    local session = get_session(target_pane)
    if not session or not session.client then
      if on_done then
        vim.schedule(function()
          on_done(nil, {
            code = -32602,
            message = "ACP session is not ready",
          })
        end)
      end
      return false
    end

    if not session.client:supports_session_list() then
      if on_done then
        vim.schedule(function()
          on_done(nil, {
            code = -32602,
            message = "ACP agent does not support session/list",
          })
        end)
      end
      return false
    end

    local params = {}
    if not (opts and opts.all_cwds == true) then
      params.cwd = session.cwd
    end

    list_all_sessions_for_client(session.client, params, function(items, err)
      if err then
        if on_done then
          vim.schedule(function()
            on_done(nil, err)
          end)
        end
        return
      end

      local sessions_out = {}
      local by_id = {}
      for _, item in ipairs(items or {}) do
        local normalized = normalize_session_info(item.sessionId, item)
        sessions_out[#sessions_out + 1] = normalized
        by_id[normalized.sessionId] = normalized
      end

      if session.session_info and session.session_info.sessionId and session.session_info.sessionId ~= "" then
        local existing = by_id[session.session_info.sessionId]
        if existing then
          by_id[session.session_info.sessionId] = normalize_session_info(existing.sessionId, session.session_info, existing)
          for idx, item in ipairs(sessions_out) do
            if item.sessionId == existing.sessionId then
              sessions_out[idx] = by_id[existing.sessionId]
              break
            end
          end
        else
          sessions_out[#sessions_out + 1] = normalize_session_info(session.session_info.sessionId, session.session_info)
        end
      end

      table.sort(sessions_out, function(a, b)
        local a_updated = tostring(a.updatedAt or "")
        local b_updated = tostring(b.updatedAt or "")
        if a_updated ~= b_updated then
          return a_updated > b_updated
        end
        return tostring(a.title or a.sessionId or "") < tostring(b.title or b.sessionId or "")
      end)

      if on_done then
        vim.schedule(function()
          on_done(sessions_out, nil)
        end)
      end
    end)
    return true
  end

  function backend.capture_native_session(target_pane, native_session, on_done)
    local session = get_session(target_pane)
    if not session or not session.client then
      if on_done then
        vim.schedule(function()
          on_done(nil, {
            code = -32602,
            message = "ACP session is not ready",
          })
        end)
      end
      return false
    end

    if type(native_session) ~= "table" or not native_session.sessionId or native_session.sessionId == "" then
      if on_done then
        vim.schedule(function()
          on_done(nil, {
            code = -32602,
            message = "Missing ACP sessionId",
          })
        end)
      end
      return false
    end

    if not session.client:supports_session_load() then
      if on_done then
        vim.schedule(function()
          on_done(nil, {
            code = -32602,
            message = "ACP agent does not support session/load",
          })
        end)
      end
      return false
    end

    capture_native_session_for_session(session, normalize_session_info(native_session.sessionId, native_session), on_done)
    return true
  end

  function backend.capture_pane(pane_id, on_output)
    local session = get_session(pane_id)
    local text = ""
    if session and vim.fn.filereadable(session.transcript_path) == 1 then
      local ok, lines = pcall(vim.fn.readfile, session.transcript_path)
      if ok and lines then
        text = table.concat(lines, "\n")
      end
    end
    if on_output then
      vim.schedule(function()
        pcall(on_output, text)
      end)
    end
    return true
  end

  function backend.capture_pane_sync(pane_id)
    local session = get_session(pane_id)
    if not session or vim.fn.filereadable(session.transcript_path) == 0 then
      return ""
    end
    local ok, lines = pcall(vim.fn.readfile, session.transcript_path)
    if not ok or not lines then
      return ""
    end
    return table.concat(lines, "\n")
  end

  function backend.clear_transcript(pane_id, replacement_text)
    local session = get_session(pane_id)
    if not session then
      return false
    end
    return clear_session_transcript(session, replacement_text)
  end

  return backend
end

M.new = create_backend

return M
