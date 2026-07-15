local M = {}

local function content_text(content)
  if type(content) ~= "table" then return tostring(content or "") end
  if content.type == "text" then return tostring(content.text or "") end
  if vim.islist(content) then
    local parts = {}
    for _, item in ipairs(content) do
      local text = content_text(item)
      if text ~= "" then parts[#parts + 1] = text end
    end
    return table.concat(parts, "\n")
  end
  return content.text and tostring(content.text) or ""
end

local function append_section(state, heading, text, stream)
  text = tostring(text or "")
  if text == "" then return end
  if stream and state.last_heading == heading then
    local lines = vim.split(text, "\n", { plain = true })
    if state.lines[#state.lines] and #lines > 0 then
      state.lines[#state.lines] = state.lines[#state.lines] .. table.remove(lines, 1)
    end
    vim.list_extend(state.lines, lines)
    return
  end
  if #state.lines > 0 then state.lines[#state.lines + 1] = "" end
  state.lines[#state.lines + 1] = "── " .. heading .. " ──"
  vim.list_extend(state.lines, vim.split(text, "\n", { plain = true }))
  state.last_heading = heading
end

local function update_from_session(state, update)
  local variant = tostring(update.sessionUpdate or update.type or "")
  if variant == "agent_message_chunk" then
    append_section(state, "Assistant", content_text(update.content), true)
    state.runtime.messages = state.runtime.messages + 1
  elseif variant == "agent_thought_chunk" or variant == "agent_thought" then
    append_section(state, "Thinking", content_text(update.content), true)
  elseif variant == "user_message_chunk" then
    append_section(state, "User", content_text(update.content), true)
  elseif variant == "tool_call" or variant == "tool_call_update" then
    append_section(state, "Tool", string.format("%s [%s]", update.title or update.toolCallId or "tool", update.status or "update"))
    state.runtime.tools = state.runtime.tools + 1
  elseif variant == "current_mode_update" then
    state.runtime.mode = update.currentModeId or update.modeId
  elseif variant == "current_model_update" then
    state.runtime.model = update.currentModelId or update.modelId
  elseif variant == "session_info_update" then
    state.runtime.title = update.title or state.runtime.title
  end
end

function M.rebuild(records, upto)
  upto = math.min(math.max(0, tonumber(upto) or #records), #records)
  local state = {
    lines = {},
    last_heading = nil,
    pending = {},
    runtime = { status = "created", messages = 0, tools = 0 },
  }
  for index = 1, upto do
    local record = records[index]
    local message = record and record.message or {}
    if record.direction == "out" and message.method then
      if message.id ~= nil then state.pending[tostring(message.id)] = message.method end
      if message.method == "initialize" then state.runtime.status = "initializing"
      elseif message.method == "session/prompt" then
        state.runtime.status = "busy"
        append_section(state, "User", content_text(message.params and message.params.prompt))
      elseif message.method == "session/cancel" then state.runtime.status = "cancelling" end
    elseif record.direction == "in" and message.method == "session/update" then
      update_from_session(state, message.params and message.params.update or {})
    elseif record.direction == "in" and message.id ~= nil then
      local method = state.pending[tostring(message.id)]
      state.pending[tostring(message.id)] = nil
      if method == "initialize" and message.result then
        state.runtime.status = "initialized"
        state.runtime.capabilities = vim.deepcopy(message.result.agentCapabilities or {})
      elseif method == "session/new" or method == "session/load" or method == "session/resume" then
        state.runtime.status = message.error and "failed" or "ready"
        state.runtime.session_id = message.result and message.result.sessionId or state.runtime.session_id
      elseif method == "session/prompt" then
        state.runtime.status = message.error and "failed" or "ready"
        state.runtime.stop_reason = message.result and message.result.stopReason or nil
      end
    end
  end
  state.pending = nil
  state.last_heading = nil
  return state
end

local function buffer_lines(records, cursor)
  local replay = M.rebuild(records, cursor)
  local runtime = replay.runtime
  local lines = {
    "LazyAgent ACP Replay",
    string.format("Event %d / %d", cursor, #records),
    string.format("Status: %s", runtime.status or "unknown"),
    string.format("Session: %s", runtime.session_id or "-"),
    string.format("Model: %s · Mode: %s", runtime.model or "-", runtime.mode or "-"),
    string.format("Messages: %d · Tools: %d", runtime.messages or 0, runtime.tools or 0),
    "",
  }
  vim.list_extend(lines, replay.lines)
  return lines
end

function M.open(path)
  local records = require("lazyagent.acp.protocol_log").read(path)
  local bufnr = vim.api.nvim_create_buf(false, true)
  local cursor = #records
  vim.api.nvim_buf_set_name(bufnr, "lazyagent://acp/replay")
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "lazyagent_acp"
  local function render(next_cursor)
    cursor = math.min(math.max(0, next_cursor), #records)
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, buffer_lines(records, cursor))
    vim.bo[bufnr].modifiable = false
  end
  vim.keymap.set("n", "l", function() render(cursor + 1) end, { buffer = bufnr, desc = "Replay next ACP event" })
  vim.keymap.set("n", "h", function() render(cursor - 1) end, { buffer = bufnr, desc = "Replay previous ACP event" })
  vim.keymap.set("n", "G", function() render(#records) end, { buffer = bufnr, desc = "Replay latest ACP event" })
  vim.keymap.set("n", "gg", function() render(0) end, { buffer = bufnr, desc = "Replay from start" })
  render(cursor)
  vim.cmd("botright new")
  vim.api.nvim_win_set_buf(0, bufnr)
  return bufnr
end

return M
