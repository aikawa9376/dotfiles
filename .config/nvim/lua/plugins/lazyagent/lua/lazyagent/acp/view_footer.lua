local M = {}

function M.new(ctx)
  local footer_ns = ctx.footer_ns or vim.api.nvim_create_namespace("lazyagent_acp_footer")
  local agent_logic = ctx.agent_logic
  local state = ctx.state

  local function session_for_agent(agent_name)
    return ctx.session_for_agent(agent_name)
  end

  local function strdisplaywidth(text)
    local ok, width = pcall(vim.fn.strdisplaywidth, text)
    return ok and width or #tostring(text or "")
  end

  local function find_config_option(session, keys)
    if not session or type(session.acp_config_options) ~= "table" then
      return nil
    end

    local function normalize_config_key(value)
      return tostring(value or ""):lower():gsub("[^%w]+", "")
    end

    keys = type(keys) == "table" and keys or { keys }
    for _, option in ipairs(session.acp_config_options) do
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

  local function current_config_details(session, keys)
    local option = find_config_option(session, keys)
    if not option then
      return nil, nil
    end

    local current = option.currentValue
    if current == nil or current == "" then
      return nil, nil
    end

    for _, choice in ipairs(option.options or {}) do
      if type(choice) == "table" and choice.value == current then
        return compact_config_value(choice.name or current), current
      end
    end

    return compact_config_value(current), current
  end

  local function format_bytes(bytes)
    if not bytes or bytes < 0 then
      return nil
    end
    if bytes < 1024 then
      return string.format("%d B", bytes)
    end

    local units = { "KiB", "MiB", "GiB", "TiB" }
    local value = bytes
    local unit = "B"
    for _, candidate in ipairs(units) do
      value = value / 1024
      unit = candidate
      if value < 1024 then
        break
      end
    end
    return string.format("%.1f %s", value, unit)
  end

  local function transcript_size_label(session)
    local path = session and session.acp_transcript_path or nil
    if not path or path == "" then
      return nil
    end
    local loop = vim.uv or vim.loop
    local stat = loop and loop.fs_stat(path) or nil
    return stat and format_bytes(stat.size) or nil
  end

  local function provider_label(agent_name, session)
    local info = session and session.acp_agent_info or {}
    local name = info.title or info.name or agent_name or "ACP"
    local version = info.version or ""
    if version ~= "" then
      return string.format("%s %s", name, version)
    end
    return name
  end

  local function current_model_usage(session)
    local _, current_model_id = current_config_details(session, { "model" })
    if not current_model_id then
      return nil
    end

    local catalog = session and session.acp_model_catalog or nil
    if type(catalog) ~= "table" then
      return nil
    end

    for _, model in ipairs(catalog.availableModels or {}) do
      if type(model) == "table" and model.modelId == current_model_id then
        local meta = model._meta or {}
        local used = tonumber(meta.token_usage_used) or (meta.usage and tonumber(meta.usage.usedTokens)) or nil
        local total = tonumber(meta.token_usage_total)
          or (meta.usage and (tonumber(meta.usage.totalTokens) or tonumber(meta.usage.contextSize)))
          or (tonumber(meta.contextSize) or tonumber(model.contextSize))
          or nil

        if not used and meta.usage and (meta.usage.promptTokens or meta.usage.completionTokens) then
          local prompt = tonumber(meta.usage.promptTokens) or 0
          local completion = tonumber(meta.usage.completionTokens) or 0
          used = prompt + completion
        end

        if used and total and total > 0 then
          return string.format("%d/%d (%.1f%%)", used, total, (used / total) * 100)
        end

        if meta.copilotUsage and meta.copilotUsage ~= "" then
          local usage = tostring(meta.copilotUsage)
          local parsed_used, parsed_total = usage:match("(%d+)%s*[/%-]%s*(%d+)")
          if parsed_used and parsed_total then
            local numeric_used = tonumber(parsed_used)
            local numeric_total = tonumber(parsed_total)
            if numeric_used and numeric_total and numeric_total > 0 then
              return string.format("%d/%d (%.1f%%)", numeric_used, numeric_total, (numeric_used / numeric_total) * 100)
            end
          end
          return usage
        end

        return nil
      end
    end

    return nil
  end

  local function session_status(agent_name, session)
    if not session then
      return "◌ Connecting...", "LazyAgentACPFooterMuted"
    end

    local message = tostring(session.agent_status_message or "")
    if session.acp_failed or message == "Disconnected" then
      return "󰅚 " .. (message ~= "" and message or "Disconnected"), "LazyAgentACPFooterError"
    end

    if session.agent_status == "waiting" then
      return " " .. (message ~= "" and message or "Waiting..."), "LazyAgentACPFooterWaiting"
    end

    if session.monitor_timer or session.agent_status == "thinking" then
      return message ~= "" and message or "Thinking...", "LazyAgentACPFooterActive"
    end

    if not session.acp_ready then
      return "◌ Connecting " .. provider_label(agent_name, session) .. "...", "LazyAgentACPFooterMuted"
    end

    return nil, nil
  end

  local function footer_debug_enabled()
    return state and state.opts and state.opts.debug == true
  end

  local function footer_display_path(path)
    path = tostring(path or "")
    if path == "" then
      return nil
    end
    local ok, display = pcall(vim.fn.fnamemodify, path, ":~:.")
    if ok and display and display ~= "" then
      return display
    end
    return path
  end

  local function footer_debug_lines(session)
    if not footer_debug_enabled() or not session then
      return {}
    end

    local lines = {}
    local identity = {}
    local resources = {}

    if session.acp_session_id and session.acp_session_id ~= "" then
      table.insert(identity, "Session " .. tostring(session.acp_session_id))
    end
    if session.pane_id and session.pane_id ~= "" then
      table.insert(identity, "Pane " .. tostring(session.pane_id))
    end
    if session.backend and session.backend ~= "" then
      table.insert(identity, "Backend " .. tostring(session.backend))
    end
    if #identity > 0 then
      table.insert(lines, { text = " " .. table.concat(identity, "  "), hl = "LazyAgentACPFooterMuted" })
    end

    local transcript_path = footer_display_path(session.acp_transcript_path or session.transcript_path)
    if transcript_path then
      table.insert(resources, "Transcript " .. transcript_path)
    end

    local mcp_url = tostring(session.mcp_url or ((state.opts and state.opts._mcp_url) or ""))
    if mcp_url ~= "" then
      table.insert(resources, "MCP " .. mcp_url)
    end

    local root_dir = footer_display_path(session.root_dir or session.cwd)
    if root_dir then
      table.insert(resources, "Root " .. root_dir)
    end

    for _, resource in ipairs(resources) do
      table.insert(lines, { text = " " .. resource, hl = "LazyAgentACPFooterMeta" })
    end

    return lines
  end

  local function footer_context_segments(agent_name, session)
    local segments = {}
    local model = select(1, current_config_details(session, { "model" }))
    if model and model ~= "" then
      table.insert(segments, model)
    end

    local mode = select(1, current_config_details(session, { "mode" }))
    if mode and mode ~= "" then
      table.insert(segments, mode)
    end

    local reasoning = select(1, current_config_details(session, { "thought_level", "reasoning_effort" }))
    if reasoning and reasoning ~= "" then
      table.insert(segments, "Reasoning " .. reasoning)
    end

    local usage = current_model_usage(session)
    if usage and usage ~= "" then
      table.insert(segments, "Usage " .. usage)
    end

    local mcp_count = tonumber(session and session.acp_mcp_server_count or 0) or 0
    if mcp_count > 0 then
      table.insert(segments, string.format("%d MCP server%s", mcp_count, mcp_count == 1 and "" or "s"))
    end

    if agent_name and session then
      local command_count = #agent_logic.get_visible_slash_commands(agent_name, session)
      table.insert(segments, string.format("%d slash cmd%s", command_count, command_count == 1 and "" or "s"))
    end

    if session and session.acp_supports_embedded_context then
      table.insert(segments, "Embedded ctx")
    end

    return segments
  end

  local function footer_context_text(agent_name, session)
    local context = footer_context_segments(agent_name, session)
    if #context > 0 then
      return table.concat(context, " · ")
    end
    return "Waiting for ACP session metadata..."
  end

  local function blank_footer_line()
    return { text = "", hl = nil }
  end

  local function wrap_footer_text(text, width)
    local wrapped = {}
    local current = {}
    local current_width = 0
    width = math.max(12, tonumber(width) or 80)

    local function push_current()
      table.insert(wrapped, table.concat(current))
      current = {}
      current_width = 0
    end

    text = tostring(text or "")
    if text == "" then
      return { "" }
    end

    for _, char in ipairs(vim.fn.split(text, "\\zs")) do
      local char_width = math.max(1, strdisplaywidth(char))
      if current_width > 0 and current_width + char_width > width then
        push_current()
      end
      table.insert(current, char)
      current_width = current_width + char_width
    end

    push_current()
    return wrapped
  end

  local function footer_render_lines(agent_name, session, line_count)
    local size = transcript_size_label(session)
    local provider = provider_label(agent_name, session)
    local context = footer_context_text(agent_name, session)
    local status_text, status_hl = session_status(agent_name, session)
    local lines = {}
    local meta = {}
    local has_status = status_text and status_text ~= ""
    local has_context = context and context ~= ""

    if provider ~= "" then
      table.insert(meta, provider)
    end

    local stats = {}
    if size then
      table.insert(stats, size)
    end
    if line_count and line_count > 0 then
      table.insert(stats, string.format("%d %s", line_count, line_count == 1 and "line" or "lines"))
    end
    if #stats > 0 then
      table.insert(meta, table.concat(stats, " / "))
    end

    if has_status then
      table.insert(lines, blank_footer_line())
      table.insert(lines, { text = " " .. status_text, hl = status_hl or "LazyAgentACPFooterMuted" })
    end

    if #meta > 0 or has_context then
      table.insert(lines, blank_footer_line())
    end

    if #meta > 0 then
      table.insert(lines, { text = " " .. table.concat(meta, "  "), hl = "LazyAgentACPFooterMuted" })
    end

    if has_context then
      table.insert(lines, { text = " " .. context, hl = "LazyAgentACPFooterMeta" })
    end

    for _, line in ipairs(footer_debug_lines(session)) do
      table.insert(lines, line)
    end

    return lines
  end

  local function render_footer_lines(bufnr)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return {}, {}
    end

    local agent_name = ctx.agent_name_for_bufnr(bufnr)
    if not agent_name or agent_name == "" then
      return {}, {}
    end

    local line_count = ctx.transcript_line_count(bufnr)
    local rendered = {}
    local highlights = {}
    for _, line in ipairs(footer_render_lines(agent_name, session_for_agent(agent_name), line_count)) do
      for _, wrapped in ipairs(wrap_footer_text(line.text or "", ctx.overlay_target_width(bufnr))) do
        table.insert(rendered, wrapped)
        table.insert(highlights, line.hl)
      end
    end
    return rendered, highlights
  end

  local function footer_signature(footer_start, footer_lines, footer_hls)
    local parts = { tostring(footer_start), tostring(#(footer_lines or {})) }
    for idx, line in ipairs(footer_lines or {}) do
      parts[#parts + 1] = tostring(footer_hls[idx] or "")
      parts[#parts + 1] = "\0"
      parts[#parts + 1] = tostring(line or "")
      parts[#parts + 1] = "\n"
    end
    return table.concat(parts)
  end

  local api = {}

  function api.statusline()
    return ""
  end

  function api.refresh_footer(bufnr, opts)
    opts = opts or {}
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    if not opts.force and not ctx.buffer_is_visible(bufnr) then
      return
    end

    local footer_start = ctx.transcript_line_count(bufnr)
    local footer_lines, footer_hls = render_footer_lines(bufnr)
    local signature = footer_signature(footer_start, footer_lines, footer_hls)
    local entry = ctx.layout_entry(bufnr)
    local padding_needed = ctx.footer_padding_count(bufnr) ~= #footer_lines
    if not opts.force and not padding_needed and entry.footer_signature == signature then
      return
    end

    vim.api.nvim_buf_clear_namespace(bufnr, footer_ns, 0, -1)
    ctx.set_footer_padding(bufnr, #footer_lines)
    entry.footer_signature = signature

    if #footer_lines == 0 then
      return
    end

    local line_count = vim.api.nvim_buf_line_count(bufnr)
    local footer_base = math.max(0, line_count - #footer_lines)
    for idx, line in ipairs(footer_lines) do
      local chunks = nil
      local hl = footer_hls[idx]
      if line ~= "" then
        if hl and hl ~= "" then
          chunks = { { line, hl } }
        else
          chunks = { { line } }
        end
      end

      if chunks then
        local row = math.min(math.max(0, line_count - 1), footer_base + idx - 1)
        vim.api.nvim_buf_set_extmark(bufnr, footer_ns, row, 0, {
          virt_text = chunks,
          virt_text_pos = "overlay",
          hl_mode = "combine",
        })
      end
    end
  end

  function api.refresh_all_footers()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if ctx.is_acp_buffer(bufnr) and ctx.buffer_is_visible(bufnr) then
        api.refresh_footer(bufnr)
      end
    end
  end

  function api.refresh_agent_footers(agent_name, opts)
    if not agent_name or agent_name == "" then
      return
    end
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if ctx.is_acp_buffer(bufnr)
        and ctx.agent_name_for_bufnr(bufnr) == agent_name
        and ctx.buffer_is_visible(bufnr)
      then
        api.refresh_footer(bufnr, opts)
      end
    end
  end

  return api
end

return M
