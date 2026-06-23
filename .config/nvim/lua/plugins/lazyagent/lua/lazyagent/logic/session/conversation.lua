local M = {}

local acp_logic = require("lazyagent.logic.acp")
local cache_logic = require("lazyagent.logic.cache")
local util = require("lazyagent.util")

local sanitize_filename_component = util.sanitize_filename_component

local SIDECAR_VERSION = 1
local SIDECAR_SUMMARY_LIMIT = 1024
local SIDECAR_BODY_LIMIT = 64 * 1024
local SIDECAR_TOOL_OUTPUT_LIMIT = 128 * 1024

local function shallow_list_copy(list)
  local out = {}
  for idx = 1, #(list or {}) do
    out[idx] = list[idx]
  end
  return out
end

local function lines_start_with(lines, prefix)
  lines = lines or {}
  prefix = prefix or {}
  if #prefix > #lines then
    return false
  end
  for idx = 1, #prefix do
    if lines[idx] ~= prefix[idx] then
      return false
    end
  end
  return true
end

local function merge_conversation_lines(previous, current)
  previous = previous or {}
  current = current or {}

  if #previous == 0 then
    return shallow_list_copy(current)
  end
  if #current == 0 then
    return shallow_list_copy(previous)
  end
  if lines_start_with(current, previous) then
    return shallow_list_copy(current)
  end
  if lines_start_with(previous, current) then
    return shallow_list_copy(previous)
  end

  local overlap = math.min(#previous, #current)
  while overlap > 0 do
    local matched = true
    for idx = 1, overlap do
      if previous[#previous - overlap + idx] ~= current[idx] then
        matched = false
        break
      end
    end
    if matched then
      break
    end
    overlap = overlap - 1
  end

  local merged = shallow_list_copy(previous)
  for idx = overlap + 1, #current do
    merged[#merged + 1] = current[idx]
  end
  return merged
end

function M.normalize_keep_line_limit(value)
  local count = tonumber(value)
  if not count or count <= 0 then
    return nil
  end
  return math.floor(count)
end

local function is_user_transcript_heading(line)
  return type(line) == "string"
    and line:match("^─ ") ~= nil
    and line:find(" User", 1, true) ~= nil
end

function M.split_conversation_checkpoint_lines(lines, keep_recent_lines)
  lines = lines or {}
  local keep_count = M.normalize_keep_line_limit(keep_recent_lines)
  if not keep_count or #lines <= keep_count then
    return {}, lines
  end

  local keep_start = #lines - keep_count + 1
  local split_start = keep_start
  for row = keep_start, 1, -1 do
    if is_user_transcript_heading(lines[row]) then
      split_start = row
      break
    end
  end

  if split_start <= 1 then
    return {}, lines
  end

  return vim.list_slice(lines, 1, split_start - 1), vim.list_slice(lines, split_start)
end

local function clamp_sidecar_text(text, byte_limit)
  text = tostring(text or "")
  byte_limit = tonumber(byte_limit) or 0
  if byte_limit <= 0 or #text <= byte_limit then
    return text
  end
  return text:sub(1, byte_limit) .. "\n… [truncated]"
end

local function serialize_conversation_timeline(items)
  local out = {}
  for _, item in ipairs(items or {}) do
    if type(item) == "table" then
      out[#out + 1] = {
        id = tostring(item.id or ""),
        seq = tonumber(item.seq or (#out + 1)) or (#out + 1),
        kind = tostring(item.kind or ""),
        heading = tostring(item.heading or ""),
        title = tostring(item.title or item.heading or ""),
        summary = clamp_sidecar_text(item.summary or "", SIDECAR_SUMMARY_LIMIT),
        body = clamp_sidecar_text(item.body or "", SIDECAR_BODY_LIMIT),
        body_ref = vim.deepcopy(item.body_ref),
        pinned = item.pinned == true,
        toolCallId = item.toolCallId,
        status = item.status,
        path = item.path,
      }
    end
  end
  return out
end

local function serialize_tool_timeline(entries)
  local out = {}
  for _, entry in ipairs(entries or {}) do
    if type(entry) == "table" then
      out[#out + 1] = {
        toolCallId = tostring(entry.toolCallId or ""),
        seq = tonumber(entry.seq or (#out + 1)) or (#out + 1),
        title = tostring(entry.title or entry.toolCallId or "tool"),
        heading = tostring(entry.heading or ""),
        status = tostring(entry.status or ""),
        kind = tostring(entry.kind or ""),
        summary = clamp_sidecar_text(entry.summary or "", SIDECAR_SUMMARY_LIMIT),
        paths = vim.deepcopy(entry.paths or {}),
        pinned = entry.pinned == true,
        conversation_item_id = entry.conversation_item_id,
        rendered_content = clamp_sidecar_text(entry.rendered_content or "", SIDECAR_TOOL_OUTPUT_LIMIT),
        rendered_raw_output = clamp_sidecar_text(entry.rendered_raw_output or "", SIDECAR_TOOL_OUTPUT_LIMIT),
        rendered_content_ref = vim.deepcopy(entry.rendered_content_ref),
        rendered_raw_output_ref = vim.deepcopy(entry.rendered_raw_output_ref),
      }
    end
  end
  return out
end

local function collect_pinned_ids(items, tools)
  local ids = {}
  local seen = {}
  for _, item in ipairs(items or {}) do
    if type(item) == "table" and item.pinned == true and item.id and item.id ~= "" and not seen[item.id] then
      seen[item.id] = true
      ids[#ids + 1] = item.id
    end
  end
  for _, tool in ipairs(tools or {}) do
    if type(tool) == "table" and tool.pinned == true then
      local id = tool.conversation_item_id or (tool.toolCallId and ("tool:" .. tostring(tool.toolCallId))) or nil
      if id and not seen[id] then
        seen[id] = true
        ids[#ids + 1] = id
      end
    end
  end
  return ids
end

local function merge_sidecar_entries(previous, current, key)
  local merged = {}
  local index = {}

  for _, item in ipairs(previous or {}) do
    if type(item) == "table" then
      local copy = vim.deepcopy(item)
      merged[#merged + 1] = copy
      local id = copy[key]
      if id and id ~= "" then
        index[id] = #merged
      end
    end
  end

  for _, item in ipairs(current or {}) do
    if type(item) == "table" then
      local copy = vim.deepcopy(item)
      local id = copy[key]
      local idx = id and id ~= "" and index[id] or nil
      if idx then
        merged[idx] = vim.tbl_deep_extend("force", merged[idx], copy)
      else
        merged[#merged + 1] = copy
        if id and id ~= "" then
          index[id] = #merged
        end
      end
    end
  end

  return merged
end

function M.build_conversation_sidecar(agent_name, session, path, lines)
  local conversation_timeline = serialize_conversation_timeline(session.acp_conversation_timeline or session.conversation_timeline or {})
  local tool_timeline = serialize_tool_timeline(session.acp_tool_timeline or session.tool_timeline or {})
  return {
    version = SIDECAR_VERSION,
    kind = "lazyagent-acp-conversation",
    agent_name = agent_name,
    saved_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    conversation_log_path = path,
    line_count = #(lines or {}),
    conversation_timeline = conversation_timeline,
    tool_timeline = tool_timeline,
    pinned_ids = collect_pinned_ids(conversation_timeline, tool_timeline),
  }
end

local function merge_conversation_metadata(previous, current)
  local merged = {}
  for key, value in pairs(previous or {}) do
    if key ~= "conversation_timeline" and key ~= "tool_timeline" and key ~= "pinned_ids" then
      merged[key] = value
    end
  end
  merged.version = current.version or merged.version
  merged.kind = current.kind or merged.kind
  merged.agent_name = current.agent_name or merged.agent_name
  merged.saved_at = current.saved_at or merged.saved_at
  merged.conversation_log_path = current.conversation_log_path or merged.conversation_log_path
  merged.line_count = current.line_count or merged.line_count
  merged.conversation_timeline = merge_sidecar_entries(
    previous and previous.conversation_timeline or {},
    current.conversation_timeline or {},
    "id"
  )
  merged.tool_timeline = merge_sidecar_entries(
    previous and previous.tool_timeline or {},
    current.tool_timeline or {},
    "toolCallId"
  )
  merged.pinned_ids = collect_pinned_ids(merged.conversation_timeline, merged.tool_timeline)
  return merged
end

local function should_write_conversation_sidecar(session)
  if not session then
    return false
  end
  if session.backend and acp_logic.is_acp_backend(session.backend) then
    return true
  end
  return type(session.acp_conversation_timeline) == "table"
    or type(session.acp_tool_timeline) == "table"
    or type(session.conversation_timeline) == "table"
    or type(session.tool_timeline) == "table"
end

function M.build_resume_prompt(path, metadata)
  local lines = {
    "Use the following saved ACP conversation as the current context for this new session.",
    "",
    "Transcript:",
    "@" .. path,
  }

  local pinned = {}
  for _, item in ipairs(metadata and metadata.conversation_timeline or {}) do
    if type(item) == "table" and item.pinned == true then
      pinned[#pinned + 1] = item
    end
  end
  table.sort(pinned, function(a, b)
    return (tonumber(a.seq) or 0) < (tonumber(b.seq) or 0)
  end)

  if #pinned > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Pinned context:"
    for _, item in ipairs(pinned) do
      local label = item.heading or item.kind or "Item"
      local summary = item.summary ~= "" and item.summary or item.title or label
      lines[#lines + 1] = string.format("- [%s] %s", label, summary)
    end
  end

  local tools = vim.deepcopy(metadata and metadata.tool_timeline or {})
  table.sort(tools, function(a, b)
    return (tonumber(a.seq) or 0) < (tonumber(b.seq) or 0)
  end)
  if #tools > 6 then
    local recent = {}
    for idx = math.max(#tools - 5, 1), #tools do
      recent[#recent + 1] = tools[idx]
    end
    tools = recent
  end
  if #tools > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Recent tool activity:"
    for _, tool in ipairs(tools) do
      local status = tool.status ~= "" and (" [" .. tool.status .. "]") or ""
      local summary = tool.summary ~= "" and (" - " .. tool.summary) or ""
      lines[#lines + 1] = string.format("- %s%s%s", tool.title or tool.toolCallId or "tool", status, summary)
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "Treat the transcript and notes above as the existing context. Continue from there without asking me to restate it."
  return table.concat(lines, "\n")
end

local function provider_switch_cache_dir()
  local dir = cache_logic.get_cache_dir() .. "/acp/provider-switch"
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
  return dir
end

local function session_source_bufnr(session)
  local cfg = type(session) == "table" and session.agent_cfg or nil
  local bufnr = cfg and (cfg.source_bufnr or cfg.origin_bufnr) or nil
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    return bufnr
  end
  return nil
end

function M.write_provider_switch_snapshot(agent_name, lines)
  local loop = vim.uv or vim.loop
  local stamp = loop and tostring(loop.hrtime()) or tostring(os.time())
  local path = string.format(
    "%s/%s-%s.log",
    provider_switch_cache_dir(),
    sanitize_filename_component(agent_name),
    stamp
  )
  local ok = pcall(vim.fn.writefile, lines or {}, path)
  if not ok then
    return nil
  end
  return path
end

function M.read_saved_conversation_lines(path)
  if not path or path == "" or vim.fn.filereadable(path) == 0 then
    return nil
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or type(lines) ~= "table" then
    return nil
  end
  return lines
end

function M.select_saved_conversation(prompt, on_select)
  local entries = cache_logic.list_conversation_files()
  if not entries or #entries == 0 then
    vim.notify("LazyAgentResume: no conversation snapshots found in " .. cache_logic.get_conversation_dir(), vim.log.levels.INFO)
    return
  end

  local dir = cache_logic.get_conversation_dir()
  local prefix = (cache_logic.build_cache_prefix and cache_logic.build_cache_prefix()) or ""
  local choices = {}
  if prefix ~= "" then
    local matched, rest = {}, {}
    for _, e in ipairs(entries) do
      if e.name:lower():sub(1, #prefix) == prefix:lower() then
        table.insert(matched, e.name)
      else
        table.insert(rest, e.name)
      end
    end
    for _, n in ipairs(matched) do table.insert(choices, n) end
    for _, n in ipairs(rest) do table.insert(choices, n) end
  else
    for _, e in ipairs(entries) do table.insert(choices, e.name) end
  end

  vim.ui.select(choices, {
    prompt = prompt or "Resume LazyAgent conversation:",
    previewer = "builtin",
    cwd = dir,
  }, function(selected, idx)
    local choice = (idx and choices[idx]) or selected
    if not choice or choice == "" then
      return
    end
    on_select(dir:gsub("/$", "") .. "/" .. choice)
  end)
end

function M.persist_conversation_capture(agent_name, session, lines, opts)
  opts = opts or {}

  local dir = cache_logic.get_conversation_dir()
  local prefix = cache_logic.build_cache_prefix(session_source_bufnr(session))
  local sanitized = tostring(agent_name):gsub("[^%w-_]+", "-")
  local path = session.last_save_path
  local saved_lines = lines
  local reuse_path = false

  if path and session.last_save_content then
    if lines_start_with(lines, session.last_save_content) then
      reuse_path = true
    elseif opts.merge_with_last_save then
      reuse_path = true
      saved_lines = merge_conversation_lines(session.last_save_content, lines)
    end
  end

  if not reuse_path or not path then
    local filename = prefix .. sanitized .. "-conversation-" .. os.date("%Y-%m-%d-%H%M%S") .. ".log"
    path = dir .. "/" .. filename
  end

  pcall(vim.fn.writefile, saved_lines, path)
  local metadata = nil
  if should_write_conversation_sidecar(session) then
    metadata = M.build_conversation_sidecar(agent_name, session, path, saved_lines)
    if reuse_path and session.last_save_metadata then
      metadata = merge_conversation_metadata(session.last_save_metadata, metadata)
    end
    pcall(cache_logic.write_conversation_metadata, path, metadata)
  end
  session.last_save_path = path
  session.last_save_content = saved_lines
  session.last_save_metadata = metadata
  return path, saved_lines
end

return M
