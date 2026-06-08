local M = {}

function M.setup(deps)
  local local_commands = deps.local_commands
  local sanitize_filename_component = deps.sanitize_filename_component
  local open_report_buffer = deps.open_report_buffer

  local module = {}

  local function compact_single_line(text)
    text = tostring(text or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then
      return nil
    end
    return text
  end

  local function normalize_config_key(value)
    return tostring(value or ""):lower():gsub("[^%w]+", "")
  end

  local function first_number(...)
    for idx = 1, select("#", ...) do
      local raw = select(idx, ...)
      if raw ~= nil then
        local value = tonumber(raw)
        if value ~= nil then
          return value
        end
      end
    end
    return nil
  end

  local function format_bytes(bytes)
    bytes = tonumber(bytes)
    if not bytes or bytes < 0 then
      return nil
    end
    if bytes < 1024 then
      return string.format("%d B", bytes)
    end

    local value = bytes
    local unit = "B"
    for _, candidate in ipairs({ "KiB", "MiB", "GiB", "TiB" }) do
      value = value / 1024
      unit = candidate
      if value < 1024 then
        break
      end
    end
    return string.format("%.1f %s", value, unit)
  end

  local function format_tokens(value)
    value = tonumber(value)
    if not value then
      return nil
    end
    if value >= 1000000 then
      return string.format("%.1fM", value / 1000000):gsub("%.0M$", "M")
    end
    if value >= 1000 then
      return string.format("%.1fk", value / 1000):gsub("%.0k$", "k")
    end
    return tostring(math.floor(value + 0.5))
  end

  local function format_percent(value)
    value = tonumber(value)
    if not value then
      return nil
    end
    return string.format("%.1f%%", value):gsub("%.0%%$", "%%")
  end

  local function format_time(value)
    value = tonumber(value)
    if not value or value <= 0 then
      return nil
    end
    return os.date("%Y-%m-%d %H:%M:%S", value)
  end

  local function file_stat(path)
    if type(path) ~= "string" or path == "" then
      return nil
    end
    local loop = vim.uv or vim.loop
    return loop and loop.fs_stat(path) or nil
  end

  local function file_line_count(path)
    if type(path) ~= "string" or path == "" or vim.fn.filereadable(path) ~= 1 then
      return nil
    end
    if vim.fn.executable("wc") == 1 then
      local data = vim.fn.systemlist({ "wc", "-l", path })
      if vim.v.shell_error == 0 and type(data) == "table" and data[1] then
        local count = tostring(data[1]):match("^%s*(%d+)")
        if count then
          return tonumber(count)
        end
      end
    end
    return nil
  end

  local function text_ref_size(ref, inline_text)
    if type(ref) == "table" then
      local bytes = tonumber(ref.bytes)
      if bytes then
        return bytes
      end
      local stat = file_stat(ref.path)
      if stat and stat.size then
        return stat.size
      end
    end
    inline_text = tostring(inline_text or "")
    if inline_text ~= "" then
      return #inline_text
    end
    return nil
  end

  local function config_current_value(session, expected)
    expected = normalize_config_key(expected)
    for _, option in ipairs(session and session.config_options or {}) do
      if type(option) == "table" then
        local option_id = normalize_config_key(option.id)
        local category = normalize_config_key(option.category)
        local name = normalize_config_key(option.name)
        if option_id == expected or category == expected or name == expected then
          return option.currentValue
        end
      end
    end
    return nil
  end

  local function current_model_id(session)
    local catalog = session and session.model_catalog or {}
    return config_current_value(session, "model") or catalog.currentModelId
  end

  local function current_mode_id(session)
    local catalog = session and session.mode_catalog or {}
    return config_current_value(session, "mode") or catalog.currentModeId
  end

  local function model_context_usage(session)
    local model_id = current_model_id(session)
    if not model_id then
      return nil
    end
    local catalog = session and session.model_catalog or {}
    for _, model in ipairs(catalog.availableModels or {}) do
      if type(model) == "table" and model.modelId == model_id then
        local meta = type(model._meta) == "table" and model._meta or {}
        local usage = type(meta.usage) == "table" and meta.usage or {}
        local used = first_number(
          meta.token_usage_used,
          usage.used,
          usage.usedTokens,
          usage.contextUsedTokens,
          usage.contextTokens,
          usage.context_tokens,
          usage.context_used_tokens,
          usage.used_tokens
        )
        local total = first_number(
          meta.token_usage_total,
          usage.size,
          usage.contextSize,
          usage.totalContextTokens,
          usage.contextWindow,
          usage.contextLimit,
          usage.context_window,
          meta.contextSize,
          model.contextSize
        )
        if used and total and total > 0 then
          return {
            used_tokens = used,
            total_tokens = total,
            remaining_tokens = math.max(total - used, 0),
            percentage = (used / total) * 100,
          }
        end
        if meta.copilotUsage and meta.copilotUsage ~= "" then
          return {
            provider_usage = tostring(meta.copilotUsage),
          }
        end
      end
    end
    return nil
  end

  local function session_usage_snapshot(session)
    local direct = type(session and session.usage_stats) == "table" and session.usage_stats or {}
    local fallback = model_context_usage(session) or {}
    local context = type(direct.context) == "table" and vim.deepcopy(direct.context) or {}
    if context.used_tokens == nil then
      context.used_tokens = fallback.used_tokens
    end
    if context.total_tokens == nil then
      context.total_tokens = fallback.total_tokens
    end
    if context.remaining_tokens == nil and context.used_tokens ~= nil and context.total_tokens ~= nil then
      context.remaining_tokens = math.max(context.total_tokens - context.used_tokens, 0)
    end
    if context.percentage == nil then
      context.percentage = fallback.percentage
    end
    if context.percentage == nil and context.used_tokens ~= nil and context.total_tokens ~= nil and context.total_tokens > 0 then
      context.percentage = (context.used_tokens / context.total_tokens) * 100
    end
    return {
      turn = type(direct.turn) == "table" and vim.deepcopy(direct.turn) or {},
      cumulative = type(direct.cumulative) == "table" and vim.deepcopy(direct.cumulative) or {},
      context = context,
      cost = type(direct.cost) == "table" and vim.deepcopy(direct.cost) or nil,
      provider_usage = compact_single_line(direct.provider_usage or fallback.provider_usage),
      model_id = direct.model_id or current_model_id(session),
      updated_at = direct.updated_at,
    }
  end

  local function context_usage_label(context)
    context = type(context) == "table" and context or {}
    local used = tonumber(context.used_tokens)
    local total = tonumber(context.total_tokens)
    local percent = tonumber(context.percentage)
    if used and total and total > 0 then
      return string.format(
        "%s used (%s / %s)",
        format_percent((used / total) * 100) or "unknown",
        format_tokens(used) or tostring(used),
        format_tokens(total) or tostring(total)
      )
    end
    if percent then
      return format_percent(percent) .. " used"
    end
    return "unknown"
  end

  local function count_by(items, key, fallback)
    local counts = {}
    local order = {}
    for _, item in ipairs(items or {}) do
      local value = tostring(type(item) == "table" and item[key] or "")
      if value == "" then
        value = fallback or "unknown"
      end
      if not counts[value] then
        order[#order + 1] = value
        counts[value] = 0
      end
      counts[value] = counts[value] + 1
    end
    table.sort(order)
    return counts, order
  end

  local function count_summary(items, key, fallback)
    local counts, order = count_by(items, key, fallback)
    if #order == 0 then
      return "none"
    end
    local parts = {}
    for _, name in ipairs(order) do
      parts[#parts + 1] = string.format("%s=%d", name, counts[name])
    end
    return table.concat(parts, ", ")
  end

  local function append_kv(lines, key, value)
    if value == nil or value == "" then
      value = "unknown"
    end
    lines[#lines + 1] = string.format("- %s: %s", key, tostring(value))
  end

  local function transcript_details(session)
    local path = session and (session.transcript_path or session.acp_transcript_path) or nil
    local stat = file_stat(path)
    return {
      path = path,
      size = stat and stat.size or nil,
      lines = file_line_count(path),
    }
  end

  local function count_pinned(items)
    local count = 0
    for _, item in ipairs(items or {}) do
      if type(item) == "table" and item.pinned == true then
        count = count + 1
      end
    end
    return count
  end

  local function count_compacted(items)
    local count = 0
    for _, item in ipairs(items or {}) do
      if type(item) == "table" and item.compacted == true then
        count = count + 1
      end
    end
    return count
  end

  local function terminal_counts(session)
    local total = 0
    local running = 0
    local exited = 0
    local waiters = 0
    for _, terminal in pairs(session and session.terminals or {}) do
      if type(terminal) == "table" then
        total = total + 1
        if terminal.exit_status then
          exited = exited + 1
        else
          running = running + 1
        end
        if type(terminal.waiters) == "table" then
          waiters = waiters + #terminal.waiters
        end
      end
    end
    return total, running, exited, waiters
  end

  local function native_session_support(session)
    local caps = session and session.agent_capabilities or {}
    local session_caps = type(caps.sessionCapabilities) == "table" and caps.sessionCapabilities or {}
    local supported = {}
    if session_caps.list ~= nil then
      supported[#supported + 1] = "list"
    end
    if session_caps.resume ~= nil then
      supported[#supported + 1] = "resume"
    end
    if session_caps.close ~= nil then
      supported[#supported + 1] = "close"
    end
    if caps.loadSession == true then
      supported[#supported + 1] = "load"
    end
    if #supported == 0 then
      return "none advertised"
    end
    return table.concat(supported, ", ")
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

  local function permission_rule_filters(rule)
    if type(rule) ~= "table" then
      return "unknown"
    end
    local fields = {}
    for _, key in ipairs({
      "agent",
      "agent_pattern",
      "cwd",
      "cwd_pattern",
      "tool",
      "tool_pattern",
      "title",
      "title_pattern",
      "kind",
      "kind_pattern",
      "path",
      "path_pattern",
      "text_pattern",
    }) do
      if rule[key] ~= nil and rule[key] ~= "" then
        fields[#fields + 1] = key .. "=" .. vim.inspect(rule[key])
      end
    end
    if #fields == 0 then
      return "all permission requests"
    end
    return table.concat(fields, ", ")
  end

  local function append_usage_section(lines, usage)
    usage = type(usage) == "table" and usage or {}
    lines[#lines + 1] = "## Context usage"
    append_kv(lines, "Context", context_usage_label(usage.context))
    if usage.context and usage.context.remaining_tokens ~= nil then
      append_kv(lines, "Remaining", format_tokens(usage.context.remaining_tokens) or usage.context.remaining_tokens)
    end
    local turn = usage.turn or {}
    if turn.prompt_tokens ~= nil or turn.completion_tokens ~= nil or turn.total_tokens ~= nil then
      append_kv(
        lines,
        "Turn",
        string.format(
          "%s in / %s out / %s total",
          format_tokens(turn.prompt_tokens or 0) or tostring(turn.prompt_tokens or 0),
          format_tokens(turn.completion_tokens or 0) or tostring(turn.completion_tokens or 0),
          format_tokens(turn.total_tokens or 0) or tostring(turn.total_tokens or 0)
        )
      )
    end
    local cumulative = usage.cumulative or {}
    if cumulative.prompt_tokens ~= nil or cumulative.completion_tokens ~= nil or cumulative.total_tokens ~= nil then
      append_kv(
        lines,
        "Cumulative",
        string.format(
          "%s in / %s out / %s total",
          format_tokens(cumulative.prompt_tokens or 0) or tostring(cumulative.prompt_tokens or 0),
          format_tokens(cumulative.completion_tokens or 0) or tostring(cumulative.completion_tokens or 0),
          format_tokens(cumulative.total_tokens or 0) or tostring(cumulative.total_tokens or 0)
        )
      )
    end
    append_kv(lines, "Provider usage", usage.provider_usage)
    append_kv(lines, "Model", usage.model_id)
    append_kv(lines, "Updated", format_time(usage.updated_at))
  end

  local function tool_path_index(session)
    local by_path = {}
    for _, entry in ipairs(session and session.tool_timeline or {}) do
      if type(entry) == "table" then
        for _, raw_path in ipairs(entry.paths or {}) do
          local path = tostring(raw_path or "")
          if path ~= "" then
            local item = by_path[path]
            if not item then
              item = {
                path = path,
                count = 0,
                statuses = {},
                tools = {},
              }
              by_path[path] = item
            end
            item.count = item.count + 1
            item.tools[#item.tools + 1] = entry
            local status = tostring(entry.status or "unknown")
            item.statuses[status] = (item.statuses[status] or 0) + 1
          end
        end
      end
    end

    local out = {}
    for _, item in pairs(by_path) do
      out[#out + 1] = item
    end
    table.sort(out, function(a, b)
      return a.path < b.path
    end)
    return out
  end

  local function status_count_label(statuses)
    local keys = vim.tbl_keys(statuses or {})
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do
      parts[#parts + 1] = string.format("%s=%d", key, statuses[key])
    end
    return #parts > 0 and table.concat(parts, ", ") or "unknown"
  end

  local function render_doctor_report(session)
    local info = session and session.agent_info or {}
    local session_info = session and session.session_info or {}
    local usage = session_usage_snapshot(session)
    local transcript = transcript_details(session)
    local terminal_total, terminal_running, terminal_exited, terminal_waiters = terminal_counts(session)
    local permission_rules = session and session.permission_rules or {}
    local auto_cfg = session and session.auto_switch or {}
    local view_state = session and session.view_state or {}
    local lines = {
      "# ACP Doctor",
      "",
      "## Session",
    }

    append_kv(lines, "Agent", session and session.agent_name)
    append_kv(lines, "Provider", info.title or info.name or session and session.agent_name)
    append_kv(lines, "Provider version", info.version)
    append_kv(lines, "Pane", session and session.pane_id)
    append_kv(lines, "Ready", session and session.ready == true)
    append_kv(lines, "Failed", session and session.failed == true)
    append_kv(lines, "Hidden", session and session.hidden == true)
    append_kv(lines, "Status", session and (session.agent_status_message or session.agent_status))
    append_kv(lines, "CWD", session and session.cwd)
    append_kv(lines, "Root", session and session.root_dir)
    append_kv(lines, "Native session", session and session.session_id)
    append_kv(lines, "Native title", session_info.title)
    append_kv(lines, "Native status", session_info.statusLabel or session_info.status)
    append_kv(lines, "Model", current_model_id(session))
    append_kv(lines, "Mode", current_mode_id(session))

    lines[#lines + 1] = ""
    append_usage_section(lines, usage)

    lines[#lines + 1] = ""
    lines[#lines + 1] = "## Capabilities"
    append_kv(lines, "Embedded context", session and session.prompt_supports_embedded_context == true)
    append_kv(lines, "MCP servers", session and session.mcp_server_count or 0)
    append_kv(lines, "Native sessions", native_session_support(session))
    append_kv(lines, "Config options", #(session and session.config_options or {}))
    append_kv(lines, "Advertised slash commands", #(session and session.available_commands or {}))
    append_kv(lines, "Local slash commands", #local_commands.entries(session))

    lines[#lines + 1] = ""
    lines[#lines + 1] = "## Runtime"
    append_kv(lines, "Transcript", transcript.path)
    append_kv(lines, "Transcript size", format_bytes(transcript.size))
    append_kv(lines, "Transcript lines", transcript.lines)
    append_kv(lines, "Conversation items", #(session and session.conversation_timeline or {}))
    append_kv(lines, "Conversation kinds", count_summary(session and session.conversation_timeline or {}, "kind", "unknown"))
    append_kv(lines, "Tool calls", #(session and session.tool_timeline or {}))
    append_kv(lines, "Tool statuses", count_summary(session and session.tool_timeline or {}, "status", "unknown"))
    append_kv(lines, "Tool kinds", count_summary(session and session.tool_timeline or {}, "kind", "unknown"))
    append_kv(lines, "Pinned tools", count_pinned(session and session.tool_timeline or {}))
    append_kv(lines, "Compacted tools", count_compacted(session and session.tool_timeline or {}))
    append_kv(lines, "Open terminals", string.format("%d (%d running, %d exited, %d waiters)", terminal_total, terminal_running, terminal_exited, terminal_waiters))
    append_kv(lines, "Source window valid", view_state.source_winid and vim.api.nvim_win_is_valid(view_state.source_winid) or false)

    lines[#lines + 1] = ""
    lines[#lines + 1] = "## Permissions and automation"
    append_kv(lines, "Auto permission", session and session.auto_permission)
    append_kv(lines, "Permission rules", #permission_rules)
    for idx, rule in ipairs(permission_rules) do
      local action = tostring(type(rule) == "table" and (rule.action or rule.outcome) or "")
      lines[#lines + 1] = string.format(
        "- %s: %s (%s)",
        permission_rule_label(rule, idx),
        action ~= "" and action or "manual",
        permission_rule_filters(rule)
      )
    end
    append_kv(lines, "Auto switch", auto_cfg and auto_cfg.enabled == true)
    append_kv(lines, "Auto switch mode rules", #(auto_cfg and auto_cfg.mode_rules or {}))
    append_kv(lines, "Auto switch model rules", #(auto_cfg and auto_cfg.model_rules or {}))
    append_kv(lines, "Manual overrides", table.concat(vim.tbl_keys(session and session.manual_config_overrides or {}), ", "))

    local notes = {}
    local pct = tonumber(usage.context and usage.context.percentage)
    if not pct and usage.context and usage.context.used_tokens and usage.context.total_tokens and usage.context.total_tokens > 0 then
      pct = (usage.context.used_tokens / usage.context.total_tokens) * 100
    end
    if pct and pct >= 85 then
      notes[#notes + 1] = "Context usage is high; consider checkpointing, pinning only key blocks, or starting a fresh provider session."
    elseif not pct then
      notes[#notes + 1] = "No context usage telemetry has been received yet."
    end
    if transcript.size and transcript.size > 1024 * 1024 * 5 then
      notes[#notes + 1] = "Transcript is larger than 5 MiB; keep runtime compaction enabled and prefer full/raw transcript only when needed."
    end
    if terminal_running > 0 then
      notes[#notes + 1] = "There are running ACP terminals; stale jobs can be released by the provider or by restarting the ACP session."
    end
    if #permission_rules == 0 and session and session.auto_permission == nil then
      notes[#notes + 1] = "No permission rules are configured. Rules can match agent/cwd/tool/title/kind/path/text_pattern."
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = "## Notes"
    if #notes == 0 then
      lines[#lines + 1] = "- No obvious ACP health issues from local state."
    else
      for _, note in ipairs(notes) do
        lines[#lines + 1] = "- " .. note
      end
    end

    return lines
  end

  local function show_doctor_for_session(session)
    if not session then
      return false
    end
    open_report_buffer(
      session,
      "ACP Doctor " .. sanitize_filename_component(session.agent_name or "session"),
      "markdown",
      render_doctor_report(session)
    )
    return true
  end

  local function render_context_report(session)
    local usage = session_usage_snapshot(session)
    local transcript = transcript_details(session)
    local runtime_cfg = type(session and session.runtime_compaction) == "table" and session.runtime_compaction or {}
    local transcript_cfg = type(session and session.transcript_compaction) == "table" and session.transcript_compaction or {}
    local pending = type(session and session.pending_switch_history) == "table" and session.pending_switch_history or nil
    local lines = {
      "# ACP Context Budget",
      "",
    }

    append_usage_section(lines, usage)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "## Transcript"
    append_kv(lines, "Path", transcript.path)
    append_kv(lines, "Size", format_bytes(transcript.size))
    append_kv(lines, "Lines", transcript.lines)
    append_kv(lines, "Displayed tail limit", session and session.transcript_max_lines)
    append_kv(lines, "Transcript compaction", transcript_cfg.enabled == true)
    append_kv(lines, "Transcript keep recent sections", transcript_cfg.keep_recent_sections)

    lines[#lines + 1] = ""
    lines[#lines + 1] = "## Runtime memory shape"
    append_kv(lines, "Runtime compaction", runtime_cfg.enabled ~= false)
    append_kv(lines, "Keep recent items", runtime_cfg.keep_recent_items)
    append_kv(lines, "Keep recent tools", runtime_cfg.keep_recent_tools)
    append_kv(lines, "Body limit", format_bytes(runtime_cfg.body_limit))
    append_kv(lines, "Tool output limit", format_bytes(runtime_cfg.tool_output_limit))
    append_kv(lines, "Conversation items", #(session and session.conversation_timeline or {}))
    append_kv(lines, "Conversation kinds", count_summary(session and session.conversation_timeline or {}, "kind", "unknown"))
    append_kv(lines, "Tool items", #(session and session.tool_timeline or {}))
    append_kv(lines, "Pinned tools", count_pinned(session and session.tool_timeline or {}))
    append_kv(lines, "Compacted tools", count_compacted(session and session.tool_timeline or {}))

    lines[#lines + 1] = ""
    lines[#lines + 1] = "## Carryover context"
    if pending then
      append_kv(lines, "Carryover label", pending.carryover_label)
      append_kv(lines, "Provider from", pending.provider_from)
      append_kv(lines, "Transcript", pending.transcript_path)
      append_kv(lines, "Transcript lines", #(pending.transcript_lines or {}))
      append_kv(lines, "Conversation items", #(pending.conversation_timeline or {}))
      append_kv(lines, "Tool items", #(pending.tool_timeline or {}))
    else
      lines[#lines + 1] = "- No pending provider-switch carryover context."
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = "## Budget notes"
    local pct = tonumber(usage.context and usage.context.percentage)
    if pct and pct >= 90 then
      lines[#lines + 1] = "- Context usage is above 90%; a fresh session or checkpoint is likely safer before a large task."
    elseif pct and pct >= 75 then
      lines[#lines + 1] = "- Context usage is above 75%; pin only important blocks and avoid importing full transcripts unless needed."
    elseif pct then
      lines[#lines + 1] = "- Context headroom looks acceptable from the latest usage telemetry."
    else
      lines[#lines + 1] = "- This provider has not reported context usage yet."
    end
    if count_compacted(session and session.tool_timeline or {}) > 0 then
      lines[#lines + 1] = "- Some old tool outputs are compacted; use raw/full transcript for exact old output."
    end
    if runtime_cfg.enabled == false then
      lines[#lines + 1] = "- Runtime compaction is disabled; long ACP sessions can retain more Lua-side state."
    end

    return lines
  end

  local function show_context_budget_for_session(session)
    if not session then
      return false
    end
    open_report_buffer(
      session,
      "ACP Context " .. sanitize_filename_component(session.agent_name or "session"),
      "markdown",
      render_context_report(session)
    )
    return true
  end

  local function render_tool_review_report(session)
    local timeline = session and session.tool_timeline or {}
    local paths = tool_path_index(session)
    local lines = {
      "# ACP Tool Review",
      "",
      "## Summary",
    }
    append_kv(lines, "Total tools", #timeline)
    append_kv(lines, "Statuses", count_summary(timeline, "status", "unknown"))
    append_kv(lines, "Kinds", count_summary(timeline, "kind", "unknown"))
    append_kv(lines, "Pinned", count_pinned(timeline))
    append_kv(lines, "Compacted", count_compacted(timeline))
    append_kv(lines, "Touched paths", #paths)

    lines[#lines + 1] = ""
    lines[#lines + 1] = "## Paths"
    if #paths == 0 then
      lines[#lines + 1] = "- No file paths were detected in ACP tool calls."
    else
      for _, item in ipairs(paths) do
        lines[#lines + 1] = string.format("- `%s` (%d tools; %s)", item.path, item.count, status_count_label(item.statuses))
      end
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = "## Timeline"
    if #timeline == 0 then
      lines[#lines + 1] = "- No ACP tool calls have been recorded for this session yet."
    else
      for _, entry in ipairs(timeline) do
        if type(entry) == "table" then
          local title = tostring(entry.title or entry.toolCallId or "tool")
          local status = tostring(entry.status or "unknown")
          lines[#lines + 1] = ""
          lines[#lines + 1] = string.format("### %02d. %s [%s]", tonumber(entry.seq) or 0, title, status)
          append_kv(lines, "ID", entry.toolCallId)
          append_kv(lines, "Kind", entry.kind)
          if entry.summary and entry.summary ~= "" then
            append_kv(lines, "Summary", entry.summary)
          end
          local content_bytes = text_ref_size(entry.rendered_content_ref, entry.rendered_content)
          local raw_bytes = text_ref_size(entry.rendered_raw_output_ref, entry.rendered_raw_output)
          append_kv(
            lines,
            "Output",
            string.format("content=%s, raw=%s", format_bytes(content_bytes) or "none", format_bytes(raw_bytes) or "none")
          )
          append_kv(lines, "Pinned", entry.pinned == true)
          append_kv(lines, "Compacted", entry.compacted == true)
          if type(entry.paths) == "table" and #entry.paths > 0 then
            lines[#lines + 1] = "- Paths:"
            for _, path in ipairs(entry.paths) do
              lines[#lines + 1] = "  - `" .. tostring(path) .. "`"
            end
          end
        end
      end
    end

    return lines
  end

  local function show_tool_review_for_session(session)
    if not session then
      return false
    end
    open_report_buffer(
      session,
      "ACP Tool Review " .. sanitize_filename_component(session.agent_name or "session"),
      "markdown",
      render_tool_review_report(session)
    )
    return true
  end

  module.render_doctor_report = render_doctor_report
  module.render_context_report = render_context_report
  module.render_tool_review_report = render_tool_review_report
  module.show_doctor_for_session = show_doctor_for_session
  module.show_context_budget_for_session = show_context_budget_for_session
  module.show_tool_review_for_session = show_tool_review_for_session

  return module
end

return M
