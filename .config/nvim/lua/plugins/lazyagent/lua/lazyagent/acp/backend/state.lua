
local M = {}

function M.setup(deps)
  local cache_logic = deps.cache_logic
  local util = deps.util
  local state = deps.state
  local normalize_text = deps.normalize_text
  local append_block = deps.append_block
  local sanitize_filename_component = util.sanitize_filename_component
  local clear_pending_switch_history
  local sync_runtime_live_state
  local sync_runtime_session

  local module = {}

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

local function reload_loaded_buffers_for_path(path)
  local normalized = vim.fn.fnamemodify(path or "", ":p")
  if normalized == "" or vim.fn.filereadable(normalized) ~= 1 then
    return { reloaded = 0, skipped_modified = 0 }
  end

  local result = { reloaded = 0, skipped_modified = 0 }
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "" and vim.fn.fnamemodify(name, ":p") == normalized and vim.bo[bufnr].buftype == "" then
        if vim.bo[bufnr].modified then
          result.skipped_modified = result.skipped_modified + 1
        else
          pcall(vim.cmd, "silent checktime " .. tostring(bufnr))
          result.reloaded = result.reloaded + 1
        end
      end
    end
  end

  return result
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
    end)
  end
  return ok
end

local function prune_saved_session_snapshots(agent_name, pane_id, opts)
  if not agent_name or agent_name == "" then
    return
  end

  opts = opts or {}
  local pane_key = pane_id and tostring(pane_id) or nil
  for session_name, view in pairs(state.session_views or {}) do
    if type(view) == "table" and type(view.agents) == "table" then
      local snapshot = view.agents[agent_name]
      if type(snapshot) == "table" then
        local snapshot_pane_key = snapshot.pane_id and tostring(snapshot.pane_id) or nil
        if pane_key == nil or snapshot_pane_key == pane_key then
          if opts.purge == true then
            view.agents[agent_name] = nil
            if type(view.visible_agents) == "table" then
              view.visible_agents[agent_name] = nil
            end
            if view.last_agent == agent_name then
              view.last_agent = nil
            end
            if view.open_agent == agent_name then
              view.open_agent = nil
            end
            local has_agents = next(view.agents) ~= nil
            local has_visible = type(view.visible_agents) == "table" and next(view.visible_agents) ~= nil
            if not has_agents and not has_visible and not view.last_agent and not view.open_agent then
              state.session_views[session_name] = nil
            end
          else
            snapshot.pending_switch_history = nil
            snapshot.conversation_timeline = nil
            snapshot.conversation_timeline_index = nil
            snapshot.conversation_next_item_id = 0
            snapshot.tool_calls = nil
            snapshot.tool_timeline = nil
            snapshot.tool_timeline_index = nil
            snapshot.acp_conversation_timeline = {}
            snapshot.acp_tool_timeline = {}
            if type(snapshot.view_state) == "table" then
              local source_winid = snapshot.view_state.source_winid
              snapshot.view_state = source_winid ~= nil and { source_winid = source_winid } or nil
            end
          end
        end
      end
    end
  end
end

local function compact_session_view_state(session)
  if not session then
    return
  end

  local view = session.view
  if view and type(view.release_session_resources) == "function" then
    pcall(view.release_session_resources, session)
    return
  end

  local view_state = type(session.view_state) == "table" and session.view_state or nil
  local source_winid = view_state and view_state.source_winid or nil
  session.view_state = source_winid ~= nil and { source_winid = source_winid } or {}
end

local function clear_session_timeline_state(session)
  if not session then
    return
  end

  clear_pending_switch_history(session)
  compact_session_view_state(session)
  session.current_stream_key = nil
  session.current_stream_heading = nil
  session.current_stream_at_line_start = nil
  session.current_stream_item_id = nil
  session.conversation_timeline = {}
  session.conversation_timeline_index = {}
  session.conversation_next_item_id = 0
  session.tool_calls = {}
  session.tool_timeline = {}
  session.tool_timeline_index = {}
  prune_saved_session_snapshots(session.agent_name, session.pane_id, { purge = false })
end

local function release_closing_session_memory(session)
  if not session then
    return
  end

  clear_session_timeline_state(session)
  session.available_commands = {}
  session.config_options = {}
  session.session_info = {}
  session.agent_info = {}
  session.agent_capabilities = {}
  session.model_catalog = {}
  session.mode_catalog = {}
  session.usage_stats = {}
  session.permission_rules = {}
  session.auto_switch = {}
  session.manual_config_overrides = {}
  session.prompt_queue = {}
  session.terminals = {}
  session.last_output = ""
  prune_saved_session_snapshots(session.agent_name, session.pane_id, { purge = true })
end

local function clear_session_transcript(session, replacement_text)
  if not session or not session.transcript_path or session.transcript_path == "" then
    return false
  end

  local text = normalize_text(replacement_text or "")
  local ok = write_session_transcript(session, text, "w")
  if ok then
    session.transcript_has_content = text ~= ""
    clear_session_timeline_state(session)
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

  module.build_transcript_path = build_transcript_path
  module.file_uri = file_uri
  module.read_buffer_lines_for_path = read_buffer_lines_for_path
  module.read_path_lines = read_path_lines
  module.reload_loaded_buffers_for_path = reload_loaded_buffers_for_path
  module.clamp_utf8_from_end = clamp_utf8_from_end
  module.ensure_parent_dir = ensure_parent_dir
  module.write_transcript = write_transcript
  module.write_session_transcript = write_session_transcript
  module.clear_session_transcript = clear_session_transcript
  module.clear_pending_switch_history = clear_pending_switch_history
  module.release_closing_session_memory = release_closing_session_memory
  module.rebuild_conversation_index = rebuild_conversation_index
  module.rebuild_tool_index = rebuild_tool_index
  module.first_nonempty = first_nonempty
  module.first_number = first_number
  module.normalize_session_info = normalize_session_info
  module.update_session_info = update_session_info
  module.update_usage_stats = update_usage_stats
  module.restore_switch_snapshot = restore_switch_snapshot
  module.sync_runtime_live_state = sync_runtime_live_state
  module.sync_runtime_session = sync_runtime_session

  return module
end

return M
