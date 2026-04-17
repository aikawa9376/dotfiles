local M = {}

local cache_logic = require("lazyagent.logic.cache")
local ACPClient = require("lazyagent.acp.client")
local local_commands = require("lazyagent.acp.local_commands")
local acp_logic = require("lazyagent.logic.acp")
local summary_logic = require("lazyagent.logic.summary")
local transforms = require("lazyagent.transforms")

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
local resolve_permission_option
local tool_heading
local buffer_root_for_session

local function sanitize_filename_component(text)
  return tostring(text or ""):gsub("[^%w-_]+", "-")
end

local function transcript_dir()
  local dir = cache_logic.get_cache_dir() .. "/acp"
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
  return dir
end

local function build_transcript_path(agent_name, source_bufnr)
  return table.concat({
    transcript_dir(),
    "/",
    cache_logic.build_cache_prefix(source_bufnr),
    sanitize_filename_component(agent_name),
    "-live.log",
  })
end

local function get_session(pane_id)
  return sessions[pane_id]
end

local function normalize_text(text)
  return tostring(text or ""):gsub("\r\n", "\n")
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
    end)
  end
  return ok
end

local function section_icon_for_heading(heading)
  if heading:match("^Tool") then
    return "󱁤"
  end
  if heading:match("^Terminal") then
    return ""
  end
  if heading:match("^Edited ") then
    return "󰏫"
  end
  return section_icons[heading] or "󰈔"
end

local function section_title(heading)
  return section_icon_for_heading(heading) .. " " .. heading
end

local function section_width(heading)
  local ok, width = pcall(vim.fn.strdisplaywidth, section_title(heading))
  width = ok and width or #section_title(heading)
  return math.max(44, width + 24)
end

local function section_has_tail(heading)
  return heading == "User" or heading == "Assistant"
end

local function render_section_header(heading)
  local title = section_title(heading)
  if not section_has_tail(heading) then
    return "─ " .. title .. "\n"
  end
  local total = section_width(heading)
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

local function render_section_block(heading, body)
  body = normalize_text(body)
  if body == "" then
    return ""
  end
  local lines = { render_section_header(heading), pad_block_text(body) }
  if not body:match("\n$") then
    table.insert(lines, "\n")
  end
  return table.concat(lines)
end

local function close_stream(session)
  if session.current_stream_key then
    if not session.current_stream_at_line_start then
      write_session_transcript(session, "\n")
    end
    session.current_stream_key = nil
    session.current_stream_heading = nil
    session.current_stream_at_line_start = nil
    session.transcript_has_content = true
  end
end

local function append_block(session, heading, body)
  body = normalize_text(body)
  if body == "" then return end
  close_stream(session)
  local prefix = session.transcript_has_content and "\n" or ""
  write_session_transcript(session, prefix .. render_section_block(heading, body))
  session.transcript_has_content = true
end

local function append_stream_chunk(session, stream_key, heading, body)
  body = normalize_text(body)
  if body == "" then return end
  if session.current_stream_key ~= stream_key then
    close_stream(session)
    local prefix = session.transcript_has_content and "\n" or ""
    write_session_transcript(session, prefix .. render_section_header(heading))
    session.current_stream_key = stream_key
    session.current_stream_heading = heading
    session.current_stream_at_line_start = true
    session.transcript_has_content = true
  end
  local padded, next_at_line_start = pad_stream_chunk(body, session.current_stream_at_line_start)
  write_session_transcript(session, padded)
  session.current_stream_at_line_start = next_at_line_start
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
        local path = item.path or ""
        local diff = table.concat({
          "--- " .. path,
          item.oldText or "",
          "+++ " .. path,
          item.newText or "",
        }, "\n")
        table.insert(parts, diff)
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
  entry.tool = vim.deepcopy(tool)

  if not idx then
    session.tool_timeline[#session.tool_timeline + 1] = entry
    session.tool_timeline_index[tool.toolCallId] = #session.tool_timeline
  else
    session.tool_timeline[idx] = entry
  end
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
      local desc = tostring(command.description or "")
      local hint = command.input and command.input.hint or nil
      if hint and hint ~= "" then
        desc = (desc ~= "" and (desc .. " - " .. hint)) or hint
      end
      table.insert(out, {
        label = "/" .. tostring(command.name),
        desc = desc,
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

local function sync_runtime_session(session)
  local ok_state, state = pcall(require, "lazyagent.logic.state")
  if not ok_state or not state or not state.sessions or not state.sessions[session.agent_name] then
    return
  end

  local runtime = state.sessions[session.agent_name]
  runtime.acp_available_commands = vim.deepcopy(session.available_commands or {})
  runtime.acp_config_options = vim.deepcopy(session.config_options or {})
  runtime.acp_session_id = session.session_id
  runtime.acp_transcript_path = session.transcript_path
  runtime.acp_agent_info = vim.deepcopy(session.agent_info or {})
  runtime.acp_agent_capabilities = vim.deepcopy(session.agent_capabilities or {})
  runtime.acp_model_catalog = vim.deepcopy(session.model_catalog or {})
  runtime.acp_mode_catalog = vim.deepcopy(session.mode_catalog or {})
  runtime.acp_ready = session.ready == true
  runtime.acp_failed = session.failed == true
  runtime.acp_supports_embedded_context = session.prompt_supports_embedded_context == true
  runtime.acp_mcp_server_count = session.mcp_server_count or ((session.mcp_url and session.mcp_url ~= "") and 1 or 0)
  runtime.acp_permission_rules = vim.deepcopy(session.permission_rules or {})
  runtime.acp_auto_switch = vim.deepcopy(session.auto_switch or {})
  runtime.acp_manual_config_overrides = vim.deepcopy(session.manual_config_overrides or {})
  runtime.acp_tool_timeline = vim.deepcopy(session.tool_timeline or {})
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
  return tostring(current)
end

local function selectable_config_options(session, category)
  local out = {}
  for _, option in ipairs(session.config_options or {}) do
    if type(option) == "table"
      and option.type == "select"
      and type(option.options) == "table"
      and #option.options > 0
    then
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

local function find_config_option(session, key)
  for _, option in ipairs(session.config_options or {}) do
    if type(option) == "table" then
      local option_key = config_option_key(option)
      if option_key == key or option.id == key then
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
  local items = move_current_choice_to_head(option)
  if #items == 0 then
    append_block(session, "System", string.format("%s does not expose any selectable values.", config_option_title(option)))
    return false
  end

  local current = option.currentValue
  vim.ui.select(items, {
    prompt = "Select " .. config_option_title(option) .. ":",
    format_item = function(item)
      local prefix = (item.value == current) and "● " or "  "
      local suffix = item.description and item.description ~= "" and (": " .. item.description) or ""
      return prefix .. (item.name or tostring(item.value)) .. suffix
    end,
  }, function(choice)
    if not choice or choice.value == current then
      return
    end
    apply_config_option_choice(session, option, choice)
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
      local current = config_option_current_name(item)
      if current and current ~= "" then
        return string.format("%s (%s)", config_option_title(item), current)
      end
      return config_option_title(item)
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
  local seen = {}

  for _, command in ipairs(local_commands.entries(session)) do
    if type(command) == "table" and command.label and not seen[command.label] then
      seen[command.label] = true
      out[#out + 1] = vim.tbl_extend("force", { source = "local" }, vim.deepcopy(command))
    end
  end

  for _, command in ipairs(session and session.available_commands or {}) do
    if type(command) == "table" and command.label and not seen[command.label] then
      seen[command.label] = true
      out[#out + 1] = vim.tbl_extend("force", { source = "agent" }, vim.deepcopy(command))
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
      local source = item.source == "local" and "local" or "agent"
      local desc = item.desc and item.desc ~= "" and (" - " .. item.desc) or ""
      return string.format("%s [%s]%s", item.label, source, desc)
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

  local body = render_tool_content(tool.content)
  if body ~= "" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Content:"
    vim.list_extend(lines, vim.split(body, "\n", { plain = true }))
  end

  local raw_output = render_tool_raw_output(tool.rawOutput)
  if raw_output ~= "" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Raw output:"
    vim.list_extend(lines, vim.split(raw_output, "\n", { plain = true }))
  end

  return lines
end

local function open_tool_timeline_buffer(entry)
  vim.cmd("belowright split")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, buf)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, render_tool_timeline_detail(entry))
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.api.nvim_buf_set_name(buf, "lazyagent://acp-tool-" .. sanitize_filename_component(entry.toolCallId or "tool"))
  vim.wo.wrap = false
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
      local status = item.status and item.status ~= "" and (" [" .. item.status .. "]") or ""
      local summary = item.summary and item.summary ~= "" and (" - " .. item.summary) or ""
      return string.format("%02d. %s%s%s", item.seq or 0, item.title or item.toolCallId or "tool", status, summary)
    end,
  }, function(choice)
    if not choice then
      return
    end
    open_tool_timeline_buffer(choice)
  end)

  return true
end

local function open_report_buffer(name, filetype, lines)
  vim.cmd("belowright split")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, buf)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.bo[buf].filetype = filetype or "markdown"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or {})
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.api.nvim_buf_set_name(buf, name)
  vim.wo.wrap = false
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
        lines[#lines + 1] = string.format(
          "- %s: %s (%d choices)",
          config_option_title(option),
          tostring(config_option_current_name(option) or "unset"),
          #(option.options or {})
        )
      end
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "## Slash commands"
  if #(session and session.available_commands or {}) == 0 then
    lines[#lines + 1] = "- None advertised"
  else
    for _, command in ipairs(session.available_commands or {}) do
      lines[#lines + 1] = string.format("- %s — %s", command.label or "", command.desc or "")
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
    "lazyagent://acp-capabilities-" .. sanitize_filename_component(session.agent_name or "session"),
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
  local scratch = ok_window and window and type(window.get_scratch_bufnr) == "function" and window.get_scratch_bufnr() or nil
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
      require("lazyagent.logic.status").start_monitor(payload.agent_name)
    end)
    return
  end

  if name == "notify_done" then
    pcall(function()
      require("lazyagent.logic.status").set_idle(payload.agent_name)
    end)
    return
  end

  if name == "notify_waiting" then
    pcall(function()
      require("lazyagent.logic.status").set_waiting(payload.agent_name, payload.message)
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
  append_block(session, tool_heading(tool), tool.title or tool.toolCallId or "Permission requested")
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
  maybe_call_mcp_tool("open_last_changed", {})
  return vim.NIL
end

local function on_client_update(session, params)
  if not params or not params.update then return end
  local update = params.update
  local kind = update.sessionUpdate

  if kind == "agent_message_chunk" then
    local text = render_content(update.content)
    append_stream_chunk(session, "assistant", "Assistant", text)
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

  if kind == "tool_call" or kind == "tool_call_update" then
    local tool = merge_tool_update(session, update)
    local title = tool.title or tool.toolCallId or "tool"
    local body = render_tool_content(tool.content)
    if body == "" then
      body = render_tool_raw_output(tool.rawOutput)
    end
    if body ~= "" then
      append_block(session, tool_heading(tool), title .. "\n" .. body)
    else
      append_block(session, tool_heading(tool), title)
    end
    if tool_update_is_terminal(tool) then
      session.tool_calls[tool.toolCallId] = nil
    end
    return
  end
end

local function on_client_exit(session, code, signal, stderr_text)
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

      local blocks = build_prompt_blocks(session, prompt)
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
        auto_permission = acp.auto_permission,
        default_mode = acp.default_mode,
        initial_model = acp.initial_model,
        initial_config_applied = false,
        view = view,
        view_state = view_state or {},
      }

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
      if session.client then
        session.client:stop()
      end
      for terminal_id, _ in pairs(session.terminals or {}) do
        pcall(terminal_release, session, { terminalId = terminal_id })
      end
      local view = session_view(session)
      if view and type(view.kill_pane) == "function" then
        view.kill_pane(pane_id, session)
      end
      sessions[pane_id] = nil
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

  return backend
end

M.new = create_backend

return M
