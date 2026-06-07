local M = {}

local FOOTER_ANIMATION_INTERVAL_MS = 100
local FOOTER_RENDER_VERSION = "fg-only-v1"

function M.new(ctx)
  local footer_ns = ctx.footer_ns or vim.api.nvim_create_namespace("lazyagent_acp_footer")
  local agent_logic = ctx.agent_logic
  local state = ctx.state
  local footer_animation_timer = nil
  local footer_animation = require("lazyagent.acp.view_footer.animation").new({ state = state })
  local footer_animation_enabled = footer_animation.enabled
  local strdisplaywidth = footer_animation.strdisplaywidth
  local ensure_footer_info_highlights = footer_animation.ensure_info_highlights
  local split_chars = footer_animation.split_chars
  local animated_footer_chunks = footer_animation.animated_chunks

  local function session_for_agent(agent_name)
    return ctx.session_for_agent(agent_name)
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

  local function compact_single_line(text)
    text = tostring(text or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then
      return nil
    end
    return text
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

  local function current_model_usage_stats(session)
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
          usage.context_window
        )
          or (tonumber(meta.contextSize) or tonumber(model.contextSize))
          or nil

        if used and total and total > 0 then
          return {
            used_tokens = used,
            total_tokens = total,
            percentage = (used / total) * 100,
          }
        end

        if meta.copilotUsage and meta.copilotUsage ~= "" then
          return {
            provider_usage = tostring(meta.copilotUsage),
          }
        end

        return nil
      end
    end

    return nil
  end

  local function compact_tokens(value)
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

  local function compact_percent(value)
    value = tonumber(value)
    if not value then
      return nil
    end
    return string.format("%.1f%%", value):gsub("%.0%%$", "%%")
  end

  local function format_context_usage(used, total)
    used = tonumber(used)
    total = tonumber(total)
    if used and total and total > 0 then
      return string.format(
        "Ctx %s (%s/%s)",
        compact_percent((used / total) * 100) or "",
        compact_tokens(used) or tostring(used),
        compact_tokens(total) or tostring(total)
      )
    end
    return nil
  end

  local function current_model_usage(session)
    local usage = current_model_usage_stats(session)
    if not usage then
      return nil
    end

    local context_text = format_context_usage(usage.used_tokens, usage.total_tokens)
    if context_text then
      return context_text
    end

    if usage.provider_usage and usage.provider_usage ~= "" then
      local usage_text = tostring(usage.provider_usage)
      local parsed_used, parsed_total = usage_text:match("(%d+)%s*[/%-]%s*(%d+)")
      if parsed_used and parsed_total then
        local numeric_used = tonumber(parsed_used)
        local numeric_total = tonumber(parsed_total)
        if numeric_used and numeric_total and numeric_total > 0 then
          return format_context_usage(numeric_used, numeric_total)
        end
      end
      return usage_text
    end

    return nil
  end

  local function footer_usage_stats(session)
    local direct = type(session and session.acp_usage_stats) == "table" and session.acp_usage_stats or {}
    local fallback = current_model_usage_stats(session) or {}
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
      provider_usage = compact_single_line(direct.provider_usage or fallback.provider_usage),
    }
  end

  local function session_info_title(session)
    local info = session and session.acp_session_info or {}
    return compact_single_line(info.title)
  end

  local function session_info_summary(session)
    local info = session and session.acp_session_info or {}
    return compact_single_line(info.summary)
  end

  local function session_info_status_label(session)
    local info = session and session.acp_session_info or {}
    return compact_single_line(info.statusLabel or info.status)
  end

  local function context_usage_segment(session)
    local usage = footer_usage_stats(session)
    local used = tonumber(usage.context and usage.context.used_tokens)
    local total = tonumber(usage.context and usage.context.total_tokens)
    if not (used and total and total > 0) then
      return current_model_usage(session), nil
    end
    local base = format_context_usage(used, total)
    local remaining = tonumber(usage.context and usage.context.remaining_tokens)
    if remaining ~= nil then
      local remaining_percent = compact_percent((remaining / total) * 100)
      return base, string.format("%s left", remaining_percent or compact_tokens(remaining) or remaining)
    end
    return base, nil
  end

  local function turn_usage_segment(session)
    local usage = footer_usage_stats(session)
    local turn = usage.turn or {}
    local prompt = tonumber(turn.prompt_tokens)
    local completion = tonumber(turn.completion_tokens)
    local total = tonumber(turn.total_tokens)
    if prompt ~= nil or completion ~= nil then
      return string.format(
        "Turn %s in / %s out",
        compact_tokens(prompt or 0) or tostring(prompt or 0),
        compact_tokens(completion or 0) or tostring(completion or 0)
      )
    end
    if total ~= nil then
      return string.format("Turn %s tok", compact_tokens(total) or total)
    end
    return nil
  end

  local function cumulative_usage_segment(session)
    local usage = footer_usage_stats(session)
    local cumulative = usage.cumulative or {}
    local prompt = tonumber(cumulative.prompt_tokens)
    local completion = tonumber(cumulative.completion_tokens)
    local total = tonumber(cumulative.total_tokens)
    if prompt ~= nil or completion ~= nil then
      return string.format(
        "Total %s in / %s out",
        compact_tokens(prompt or 0) or tostring(prompt or 0),
        compact_tokens(completion or 0) or tostring(completion or 0)
      )
    end
    if total ~= nil then
      return string.format("Total %s tok", compact_tokens(total) or total)
    end
    return nil
  end

  local function provider_usage_segment(session)
    local usage = footer_usage_stats(session)
    local text = compact_single_line(usage.provider_usage)
    if not text then
      return nil
    end
    local context_text = compact_single_line(select(1, context_usage_segment(session)))
    if context_text and text == context_text:gsub("^Ctx%s+", "") then
      return nil
    end
    return "Provider " .. text
  end

  local function session_has_animated_footer(session)
    if not session or session.acp_failed or tostring(session.agent_status_message or "") == "Disconnected" then
      return false
    end
    if not footer_animation_enabled(session) then
      return false
    end
    -- アニメ（青グラデーション）は明示的な thinking 状態のみ。
    -- 描画中（monitor_timer のみ）は灰色っぽく見えるアニメをかけずに meta 同色で出す。
    return session.agent_status == "thinking"
  end

  local function session_is_streaming(session)
    if not session then
      return false
    end
    return session.monitor_timer ~= nil and session.agent_status ~= "thinking"
  end

  local function session_status(agent_name, session)
    local info_hl = ensure_footer_info_highlights()
    if not session then
      return "◌ Connecting...", info_hl
    end

    local message = tostring(session.agent_status_message or "")
    if session.acp_failed or message == "Disconnected" then
      return "󰅚 " .. (message ~= "" and message or "Disconnected"), info_hl
    end

    if session.agent_status == "waiting" then
      return " " .. (message ~= "" and message or "Waiting..."), info_hl
    end

    if session_has_animated_footer(session) then
      return message ~= "" and message or "Thinking...", "LazyAgentACPFooterActive", true
    end

    -- 描画中（monitor_timer のみ）はアニメせず、他の情報行と同じ Meta 色で
    -- 静的にメッセージを表示する。これで描画中も色が灰色にならない。
    if session_is_streaming(session) then
      return message ~= "" and message or "Generating...", info_hl
    end

    if not session.acp_ready then
      return "◌ Connecting " .. provider_label(agent_name, session) .. "...", info_hl
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
      table.insert(lines, " " .. table.concat(identity, "  "))
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
      table.insert(lines, " " .. resource)
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

    local state_label = session_info_status_label(session)
    if state_label then
      table.insert(segments, "State " .. state_label)
    end

    local context_usage, remaining_context = context_usage_segment(session)
    if context_usage and context_usage ~= "" then
      table.insert(segments, context_usage)
    end
    if remaining_context and remaining_context ~= "" then
      table.insert(segments, remaining_context)
    end

    local turn_usage = turn_usage_segment(session)
    if turn_usage then
      table.insert(segments, turn_usage)
    end

    local cumulative_usage = cumulative_usage_segment(session)
    if cumulative_usage then
      table.insert(segments, cumulative_usage)
    end

    local provider_usage = provider_usage_segment(session)
    if provider_usage then
      table.insert(segments, provider_usage)
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
    return { text = "", hl = ensure_footer_info_highlights() }
  end

  local WRAP_SEPARATORS = { " · ", "  ", " " }

  local function wrap_char_level(text, width)
    local wrapped = {}
    local current = {}
    local current_width = 0

    for _, char in ipairs(split_chars(text)) do
      local char_width = math.max(1, strdisplaywidth(char))
      if current_width > 0 and current_width + char_width > width then
        wrapped[#wrapped + 1] = table.concat(current)
        current = {}
        current_width = 0
      end
      current[#current + 1] = char
      current_width = current_width + char_width
    end
    wrapped[#wrapped + 1] = table.concat(current)
    return wrapped
  end

  local function wrap_footer_text(text, width)
    text = tostring(text or "")
    width = math.max(12, tonumber(width) or 80)

    if text == "" then
      return { "" }
    end

    -- 先頭インデント（半角/タブ）を検出し、wrap 後の全行に同じ prefix を付け直す。
    local indent = text:match("^[ \t]+") or ""
    local indent_width = strdisplaywidth(indent)
    local body = indent ~= "" and text:sub(#indent + 1) or text
    local body_width = math.max(1, width - indent_width)

    local function with_indent(lines)
      if indent == "" then
        return lines
      end
      for i, line in ipairs(lines) do
        lines[i] = indent .. line
      end
      return lines
    end

    if strdisplaywidth(body) <= body_width then
      return with_indent({ body })
    end

    -- 優先度の高い区切り文字から探す（chunk の塊を途中で割らないため）。
    local segments, sep
    for _, candidate in ipairs(WRAP_SEPARATORS) do
      if body:find(candidate, 1, true) then
        segments = vim.split(body, candidate, { plain = true })
        sep = candidate
        break
      end
    end

    if not segments or #segments <= 1 then
      return with_indent(wrap_char_level(body, body_width))
    end

    local sep_width = strdisplaywidth(sep)
    local lines = {}
    local current = {}
    local current_width = 0

    for _, segment in ipairs(segments) do
      local seg_width = strdisplaywidth(segment)
      if #current == 0 then
        current[1] = segment
        current_width = seg_width
      elseif current_width + sep_width + seg_width <= body_width then
        current[#current + 1] = segment
        current_width = current_width + sep_width + seg_width
      else
        lines[#lines + 1] = table.concat(current, sep)
        current = { segment }
        current_width = seg_width
      end
    end
    if #current > 0 then
      lines[#lines + 1] = table.concat(current, sep)
    end

    -- 1 セグメントが幅超過なら、その行だけ文字単位に分解する。
    local final = {}
    for _, line in ipairs(lines) do
      if strdisplaywidth(line) <= body_width then
        final[#final + 1] = line
      else
        for _, piece in ipairs(wrap_char_level(line, body_width)) do
          final[#final + 1] = piece
        end
      end
    end
    return with_indent(final)
  end

  local function footer_render_lines(agent_name, session, line_count)
    local info_hl = ensure_footer_info_highlights()
    local size = transcript_size_label(session)
    local provider = provider_label(agent_name, session)
    local session_title = session_info_title(session)
    local session_summary = session_info_summary(session)
    local context = footer_context_text(agent_name, session)
    local status_text, status_hl, status_animate = session_status(agent_name, session)
    local lines = {}
    local meta = {}
    local has_status = status_text and status_text ~= ""
    local has_context = context and context ~= ""

    if provider ~= "" then
      table.insert(meta, provider)
    end
    if session_title and session_title ~= "" then
      table.insert(meta, session_title)
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
      table.insert(lines, { text = " " .. status_text, hl = status_hl or info_hl, animate = status_animate })
    end

    if #meta > 0 or has_context then
      table.insert(lines, blank_footer_line())
    end

    if #meta > 0 then
      table.insert(lines, { text = " " .. table.concat(meta, "  "), hl = info_hl })
    end

    if session_summary and session_summary ~= "" then
      table.insert(lines, { text = " " .. session_summary, hl = info_hl })
    end

    if has_context then
      table.insert(lines, { text = " " .. context, hl = info_hl })
    end

    for _, line in ipairs(footer_debug_lines(session)) do
      table.insert(lines, { text = line, hl = info_hl })
    end

    return lines
  end

  local function render_footer_lines(bufnr)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return {}, {}, {}
    end

    local agent_name = ctx.agent_name_for_bufnr(bufnr)
    if not agent_name or agent_name == "" then
      return {}, {}, {}
    end

    local line_count = ctx.transcript_line_count(bufnr)
    local info_hl = ensure_footer_info_highlights()
    local wrap_width = math.max(12, tonumber(ctx.overlay_target_width(bufnr)) or 80)
    local rendered = {}
    local highlights = {}
    local animations = {}
    for _, line in ipairs(footer_render_lines(agent_name, session_for_agent(agent_name), line_count)) do
      for _, wrapped in ipairs(wrap_footer_text(line.text or "", wrap_width)) do
        table.insert(rendered, wrapped)
        table.insert(highlights, line.hl or info_hl)
        table.insert(animations, line.animate == true)
      end
    end
    return rendered, highlights, animations
  end

  local function build_line_chunks(line_text, hl, animate)
    line_text = tostring(line_text or "")
    if line_text == "" then
      if hl and hl ~= "" then
        return { { " ", hl } }
      end
      return { { " " } }
    end
    if animate then
      local chunks = animated_footer_chunks(line_text)
      if chunks and #chunks > 0 then
        return chunks
      end
    end
    if hl and hl ~= "" then
      return { { line_text, hl } }
    end
    return { { line_text } }
  end

  local api = {}

  local function stop_footer_animation_timer()
    if not footer_animation_timer then
      return
    end
    pcall(function() footer_animation_timer:stop() end)
    pcall(function() footer_animation_timer:close() end)
    footer_animation_timer = nil
  end

  local function has_visible_animated_footer()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if ctx.is_acp_buffer(bufnr) and ctx.buffer_is_visible(bufnr) then
        local agent_name = ctx.agent_name_for_bufnr(bufnr)
        if agent_name and session_has_animated_footer(session_for_agent(agent_name)) then
          return true
        end
      end
    end
    return false
  end

  local function refresh_animated_footers()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if ctx.is_acp_buffer(bufnr) and ctx.buffer_is_visible(bufnr) then
        local agent_name = ctx.agent_name_for_bufnr(bufnr)
        if agent_name and session_has_animated_footer(session_for_agent(agent_name)) then
          api.refresh_footer(bufnr, { force = true })
        end
      end
    end
  end

  local function ensure_footer_animation_timer()
    if footer_animation_timer then
      return
    end

    local uv = vim.uv or vim.loop
    if not uv or not uv.new_timer then
      return
    end

    footer_animation_timer = uv.new_timer()
    if not footer_animation_timer then
      return
    end

    footer_animation_timer:start(FOOTER_ANIMATION_INTERVAL_MS, FOOTER_ANIMATION_INTERVAL_MS, vim.schedule_wrap(function()
      if not has_visible_animated_footer() then
        stop_footer_animation_timer()
        return
      end
      footer_animation.advance_frame()
      refresh_animated_footers()
    end))
  end

  local function sync_footer_animation_timer()
    if has_visible_animated_footer() then
      ensure_footer_animation_timer()
    else
      stop_footer_animation_timer()
    end
  end

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

    local footer_lines, footer_hls, footer_anims = render_footer_lines(bufnr)
    footer_hls = footer_hls or {}
    footer_anims = footer_anims or {}
    local entry = ctx.layout_entry(bufnr)
    entry.footer_extmark_ids = entry.footer_extmark_ids or {}
    entry.footer_extmark_ids = entry.footer_extmark_ids or {}

    -- 旧 virt_lines 実装で使っていた anchor extmark は不要なので明示破棄。
    if entry.footer_extmark_id then
      pcall(vim.api.nvim_buf_del_extmark, bufnr, footer_ns, entry.footer_extmark_id)
      entry.footer_extmark_id = nil
    end

    -- 静的部分の署名（アニメ frame は含めない）。
    local base_parts = { FOOTER_RENDER_VERSION, tostring(#footer_lines) }
    local has_anim = false
    for idx, line in ipairs(footer_lines) do
      local animate = footer_anims[idx] == true
      if animate then
        has_anim = true
      end
      base_parts[#base_parts + 1] = tostring(footer_hls[idx] or "")
      base_parts[#base_parts + 1] = animate and "1" or "0"
      base_parts[#base_parts + 1] = "\0"
      base_parts[#base_parts + 1] = tostring(line or "")
      base_parts[#base_parts + 1] = "\n"
    end
    local base_sig = table.concat(base_parts)

    -- 静的キャッシュ。非アニメ行の chunks は base_sig が同じ間は再利用。
    local cache = entry.footer_render_cache
    if not cache or cache.base_sig ~= base_sig then
      local rendered = {}
      for idx, line in ipairs(footer_lines) do
        local hl = footer_hls[idx]
        local animate = footer_anims[idx] == true
        if animate then
          rendered[#rendered + 1] = { animate = true, text = tostring(line or "") }
        else
          rendered[#rendered + 1] = { animate = false, chunks = build_line_chunks(line, hl, false) }
        end
      end
      cache = { base_sig = base_sig, rendered = rendered, has_anim = has_anim }
      entry.footer_render_cache = cache
    end

    -- padding は必要数とずれている時だけ調整（毎フレームの flicker 防止）。
    if ctx.footer_padding_count(bufnr) ~= #footer_lines then
      ctx.set_footer_padding(bufnr, #footer_lines)
    end

    local full_sig = cache.has_anim and (base_sig .. "@" .. tostring(footer_animation.frame())) or base_sig
    if not opts.force and entry.footer_signature == full_sig then
      sync_footer_animation_timer()
      return
    end
    entry.footer_signature = full_sig

    -- 空フッターは extmark を全削除して終了。
    if #cache.rendered == 0 then
      for idx, id in pairs(entry.footer_extmark_ids) do
        pcall(vim.api.nvim_buf_del_extmark, bufnr, footer_ns, id)
        entry.footer_extmark_ids[idx] = nil
      end
      sync_footer_animation_timer()
      return
    end

    local line_count = vim.api.nvim_buf_line_count(bufnr)
    local footer_base = math.max(0, line_count - #cache.rendered)

    for idx, item in ipairs(cache.rendered) do
      local row = math.min(math.max(0, line_count - 1), footer_base + idx - 1)
      local chunks
      if item.animate then
        chunks = animated_footer_chunks(item.text) or { { item.text, "LazyAgentACPFooterActive" } }
      else
        chunks = item.chunks
      end

      local extmark_opts = {
        virt_text = chunks,
        virt_text_pos = "overlay",
        hl_mode = "replace",
        undo_restore = false,
        right_gravity = true,
      }
      local prev_id = entry.footer_extmark_ids[idx]
      if prev_id then
        extmark_opts.id = prev_id
      end

      local ok, new_id = pcall(vim.api.nvim_buf_set_extmark, bufnr, footer_ns, row, 0, extmark_opts)
      if ok then
        entry.footer_extmark_ids[idx] = new_id
      else
        -- id が失効していた場合は作り直す。
        extmark_opts.id = nil
        local retry_ok, retry_id = pcall(vim.api.nvim_buf_set_extmark, bufnr, footer_ns, row, 0, extmark_opts)
        if retry_ok then
          entry.footer_extmark_ids[idx] = retry_id
        else
          entry.footer_extmark_ids[idx] = nil
        end
      end
    end

    -- 余分な extmark（行数が減った場合）を削除。
    for idx, id in pairs(entry.footer_extmark_ids) do
      if idx > #cache.rendered then
        pcall(vim.api.nvim_buf_del_extmark, bufnr, footer_ns, id)
        entry.footer_extmark_ids[idx] = nil
      end
    end

    sync_footer_animation_timer()
  end

  function api.refresh_all_footers(opts)
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if ctx.is_acp_buffer(bufnr) and ctx.buffer_is_visible(bufnr) then
        api.refresh_footer(bufnr, opts)
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
