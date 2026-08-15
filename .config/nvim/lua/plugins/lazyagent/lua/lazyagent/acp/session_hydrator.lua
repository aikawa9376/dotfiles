local StructuredHistory = require("lazyagent.acp.structured_history")

local M = {}
local Hydrator = {}
Hydrator.__index = Hydrator
local generation_sequence = 0

local history_updates = {
  user_message_chunk = true,
  agent_message_chunk = true,
  agent_thought_chunk = true,
  plan = true,
  tool_call = true,
  tool_call_update = true,
}

local function copy(value)
  return vim.deepcopy(type(value) == "table" and value or {})
end

local function content_text(content)
  if type(content) == "string" then return content end
  if type(content) == "table" then return tostring(content.text or content.content or "") end
  return ""
end

local function default_apply(session, params)
  local update = params.update
  local kind = update.sessionUpdate
  local roles = {
    user_message_chunk = "user",
    agent_message_chunk = "assistant",
    agent_thought_chunk = "thinking",
  }
  if roles[kind] then
    local key = kind .. ":" .. tostring(update.messageId or (#session.conversation_timeline + 1))
    local index = session.conversation_timeline_index[key]
    if not index then
      index = #session.conversation_timeline + 1
      session.conversation_timeline_index[key] = index
      session.conversation_timeline[index] = {
        seq = index,
        kind = roles[kind],
        message_id = update.messageId,
        body = "",
      }
    end
    session.conversation_timeline[index].body = session.conversation_timeline[index].body .. content_text(update.content)
    return
  end
  if kind == "tool_call" or kind == "tool_call_update" then
    local id = tostring(update.toolCallId or "")
    local index = session.tool_timeline_index[id]
    if not index then
      index = #session.tool_timeline + 1
      session.tool_timeline_index[id] = index
      session.tool_timeline[index] = { toolCallId = id }
    end
    session.tool_timeline[index] = vim.tbl_deep_extend("force", session.tool_timeline[index], copy(update))
    return
  end
  if kind == "session_info_update" then
    session.session_info = vim.tbl_deep_extend("force", session.session_info, copy(update))
  elseif kind == "config_option_update" then
    session.config_options = copy(update.configOptions)
  elseif kind == "plan" then
    session.plan = copy(update)
  end
end

local function referenced_body(item)
  local ref = type(item) == "table" and item.body_ref or nil
  if type(ref) ~= "table" or type(ref.path) ~= "string" or vim.fn.filereadable(ref.path) ~= 1 then
    return tostring(item and item.body or "")
  end
  local ok, lines = pcall(vim.fn.readfile, ref.path)
  if not ok then return tostring(item.body or "") end
  local selected = {}
  local first = math.max(1, tonumber(ref.start_line) or 1)
  local last = math.min(#lines, tonumber(ref.end_line) or #lines)
  for index = first, last do selected[#selected + 1] = lines[index] end
  return table.concat(selected, "\n")
end

local function materialize_conversation(conversation)
  local result = copy(conversation)
  for _, item in ipairs(result) do
    if (item.body == nil or item.body == "") and item.body_ref then item.body = referenced_body(item) end
    item.body_ref = nil
  end
  return result
end

local function transcript_lines(session, conversation)
  if session.transcript_path and vim.fn.filereadable(session.transcript_path) == 1 then
    local ok, lines = pcall(vim.fn.readfile, session.transcript_path)
    if ok then return lines end
  end
  local lines = {}
  local labels = { user = "User", assistant = "Assistant", thinking = "Thinking" }
  for _, item in ipairs(conversation or session.conversation_timeline) do
    lines[#lines + 1] = "# " .. (labels[item.kind] or "System")
    vim.list_extend(lines, vim.split(tostring(item.body or ""), "\n", { plain = true }))
    lines[#lines + 1] = ""
  end
  for _, tool in ipairs(session.tool_timeline) do
    lines[#lines + 1] = "# Tool"
    lines[#lines + 1] = tostring(tool.title or tool.toolCallId or "tool") .. " [" .. tostring(tool.status or "unknown") .. "]"
    lines[#lines + 1] = ""
  end
  return lines
end

local function replay_records(generation_id, conversation, tools)
  local records = {}
  local current
  local function create(prelude)
    local record = {
      schema_version = 1,
      turn_id = generation_id .. ":" .. tostring(#records + 1),
      state = "completed",
      conversation = {},
      tools = {},
      changes = {},
    }
    if prelude then record.metadata = { native_replay_prelude = true } end
    records[#records + 1] = record
    return record
  end
  for _, item in ipairs(conversation or {}) do
    if item.kind == "user" then
      current = create(false)
    elseif not current then
      current = create(true)
    end
    current.conversation[#current.conversation + 1] = copy(item)
  end
  if #tools > 0 then
    current = current or create(true)
    current.tools = copy(tools)
  end
  return records
end

local function default_write_transcript(path, lines)
  local dir = vim.fn.fnamemodify(path, ":h")
  if vim.fn.isdirectory(dir) == 0 and vim.fn.mkdir(dir, "p", 448) == 0 then
    return nil, "failed to create hydration directory: " .. dir
  end
  local temporary = path .. ".tmp." .. tostring(vim.fn.getpid())
  local ok, result = pcall(vim.fn.writefile, lines, temporary)
  if not ok or result ~= 0 then return nil, ok and "failed to write hydration transcript" or result end
  if (vim.uv or vim.loop).fs_chmod then pcall((vim.uv or vim.loop).fs_chmod, temporary, 384) end
  local renamed, err = (vim.uv or vim.loop).fs_rename(temporary, path)
  if not renamed then pcall(vim.fn.delete, temporary); return nil, err end
  return true
end

function M.new(opts)
  opts = opts or {}
  generation_sequence = generation_sequence + 1
  local raw = table.concat({ tostring(vim.fn.getpid()), tostring((vim.uv or vim.loop).hrtime()), tostring(generation_sequence) }, ":")
  return setmetatable({
    thread = copy(opts.thread),
    base_session = opts.base_session,
    cache_dir = tostring(opts.cache_dir or vim.fn.stdpath("cache")),
    apply_update = opts.apply_update or default_apply,
    create_collector = opts.create_collector,
    clock = opts.clock or function() return os.date("!%Y-%m-%dT%H:%M:%SZ") end,
    write_transcript = opts.write_transcript or default_write_transcript,
    generation_id = vim.fn.sha256(raw):sub(1, 20),
    started_hrtime = nil,
    finished_hrtime = nil,
    state = "idle",
    owned_files = {},
    published_files = {},
    history_update_count = 0,
    byte_count = 0,
    received_byte_count = 0,
    max_bytes = tonumber(opts.max_bytes)
      or tonumber(opts.base_session and opts.base_session.runtime_compaction and opts.base_session.runtime_compaction.max_bytes)
      or (2 * 1024 * 1024),
    max_updates = tonumber(opts.max_updates) or 10000,
  }, Hydrator)
end

function Hydrator:begin()
  if self.state ~= "idle" then return nil, "hydrator already started" end
  self.collector = type(self.create_collector) == "function" and self.create_collector(self.base_session) or {
    ephemeral = true,
    runtime_sync_disabled = true,
    transcript_path = nil,
    conversation_timeline = {},
    conversation_timeline_index = {},
    tool_timeline = {},
    tool_timeline_index = {},
    tool_calls = {},
    terminals = {},
    config_options = {},
    session_info = {},
    plan = {},
  }
  self.collector.ephemeral = true
  self.collector.runtime_sync_disabled = true
  self.collector.thread_record = nil
  self.collector.view = nil
  self.collector.active_change_journal = nil
  if type(self.create_collector) == "function" then
    local raw_dir = string.format("%s/acp/hydration/%s", self.cache_dir, tostring(self.thread.thread_id))
    self.collector.transcript_path = raw_dir .. "/" .. self.generation_id .. ".collector.log"
    self.owned_files[self.collector.transcript_path] = true
  end
  self.state = "collecting"
  self.started_hrtime = (vim.uv or vim.loop).hrtime()
  return self.collector
end

function Hydrator:consume(params)
  if self.state ~= "collecting" then return nil, "hydrator is not collecting" end
  if type(params) ~= "table" or type(params.update) ~= "table" then return nil, "hydrator accepts session/update only" end
  local kind = params.update.sessionUpdate
  local encoded_ok, encoded = pcall(vim.json.encode, params.update)
  self.received_byte_count = self.received_byte_count + (encoded_ok and #encoded or 0)
  if self.history_update_count >= self.max_updates or self.received_byte_count > self.max_bytes then
    return nil, "hydration replay exceeds configured bounds"
  end
  if history_updates[kind] then self.history_update_count = self.history_update_count + 1 end
  local ok, err = pcall(self.apply_update, self.collector, copy(params))
  if not ok then return nil, err end
  return true
end

function Hydrator:prepare()
  if self.state == "prepared" or self.state == "published" then return copy(self.artifact) end
  if self.state ~= "collecting" then return nil, "hydrator cannot prepare from " .. tostring(self.state) end
  local conversation = materialize_conversation(self.collector.conversation_timeline)
  local lines = transcript_lines(self.collector, conversation)
  local records = replay_records(self.generation_id, conversation, self.collector.tool_timeline)
  self.byte_count = #table.concat(lines, "\n")
  self.artifact = {
    generation_id = self.generation_id,
    transcript_lines = lines,
    conversation_timeline = conversation,
    tool_timeline = copy(self.collector.tool_timeline),
    structured_records = records,
    session_info = copy(self.collector.session_info),
    config_options = copy(self.collector.config_options),
    history_update_count = self.history_update_count,
    byte_count = self.byte_count,
    received_byte_count = self.received_byte_count,
  }
  self.state = "prepared"
  return copy(self.artifact)
end

function Hydrator:_remove_unpublished()
  for path in pairs(self.owned_files) do
    if not self.published_files[path] then pcall(vim.fn.delete, path) end
    self.owned_files[path] = nil
  end
end

function Hydrator:publish(publish_fn)
  if self.state == "published" then return copy(self.published_thread) end
  local artifact, prepare_err = self:prepare()
  if not artifact then return nil, prepare_err end
  local activation = self.thread.metadata and self.thread.metadata.activation or {}
  local prior_state = activation.history_state or "missing"
  if prior_state == "complete" then
    self:_remove_unpublished()
    self.state = "published"
    self.finished_hrtime = (vim.uv or vim.loop).hrtime()
    self.published_thread = copy(self.thread)
    self.collector = nil
    return copy(self.published_thread)
  end
  if type(publish_fn) ~= "function" then return nil, "hydration publication callback is required" end

  local metadata = copy(self.thread.metadata)
  metadata.activation = vim.tbl_deep_extend("force", copy(metadata.activation), {
    schema_version = 1,
    history_state = artifact.history_update_count > 0 and "complete" or prior_state,
    history_source = artifact.history_update_count > 0 and "native_replay" or (activation.history_source or "none"),
  })
  local changes = { metadata = metadata }
  if artifact.history_update_count == 0 then
    metadata.activation.last_warning = "empty_replay"
  else
    metadata.activation.last_warning = nil
    metadata.activation.last_hydrated_at = self.clock()
    local dir = string.format("%s/acp/hydration/%s", self.cache_dir, tostring(self.thread.thread_id))
    local transcript_path = dir .. "/" .. self.generation_id .. ".md"
    local history_path = dir .. "/" .. self.generation_id .. ".jsonl"
    local wrote, write_err = self.write_transcript(transcript_path, artifact.transcript_lines)
    if not wrote then self:_remove_unpublished(); self.state = "failed"; return nil, write_err end
    self.owned_files[transcript_path] = true
    local history_ok, history_err = StructuredHistory.write(history_path, artifact.structured_records)
    if not history_ok then self:_remove_unpublished(); self.state = "failed"; return nil, history_err end
    self.owned_files[history_path] = true
    local read_ok, transcript = pcall(vim.fn.readfile, transcript_path)
    local records, read_err = StructuredHistory.read(history_path)
    if not read_ok or type(transcript) ~= "table" or not records or #records == 0 then
      self:_remove_unpublished()
      self.state = "failed"
      return nil, read_err or "hydration generation validation failed"
    end
    changes.transcript_path = transcript_path
    changes.history_path = history_path
  end

  local updated, publish_err = publish_fn(copy(changes), { replace_metadata = true })
  if not updated then return nil, publish_err end
  if changes.transcript_path then self.published_files[changes.transcript_path] = true end
  if changes.history_path then self.published_files[changes.history_path] = true end
  self:_remove_unpublished()
  self.state = "published"
  self.finished_hrtime = (vim.uv or vim.loop).hrtime()
  self.published_thread = copy(updated)
  self.collector = nil
  return copy(updated)
end

function Hydrator:discard(reason)
  if self.state == "discarded" then return true end
  self:_remove_unpublished()
  self.collector = nil
  self.artifact = nil
  self.discard_reason = tostring(reason or "discarded")
  self.state = "discarded"
  self.finished_hrtime = self.finished_hrtime or (vim.uv or vim.loop).hrtime()
  return true
end

function Hydrator:snapshot()
  local owned = 0
  for _ in pairs(self.owned_files) do owned = owned + 1 end
  return {
    state = self.state,
    generation_id = self.generation_id,
    history_update_count = self.history_update_count,
    byte_count = self.byte_count,
    owned_file_count = owned,
    conversation_count = self.collector and #self.collector.conversation_timeline or 0,
    tool_count = self.collector and #self.collector.tool_timeline or 0,
    duration_ms = self.started_hrtime and math.floor(
      (((self.finished_hrtime or (vim.uv or vim.loop).hrtime()) - self.started_hrtime) / 1000000) + 0.5
    ) or 0,
    owner = {
      owner_class = "activation_attempt",
      owner_id = self.generation_id,
      resource_class = "hydration_generation",
      resource_id = self.generation_id,
      count = (self.state == "collecting" or self.state == "prepared") and 1 or 0,
    },
  }
end

function Hydrator:reject_host_request(method)
  return nil, {
    code = -32600,
    message = "ACP host request is not allowed during session hydration: " .. tostring(method),
    data = { lazyagent = { kind = "hydration_host_request" } },
  }
end

return M
