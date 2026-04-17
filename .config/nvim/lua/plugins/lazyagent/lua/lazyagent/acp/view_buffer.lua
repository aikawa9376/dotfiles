local M = {}

local state = require("lazyagent.logic.state")
local pane_config = {}
local footer_state = {}
local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local transcript_ns = vim.api.nvim_create_namespace("lazyagent_acp_transcript")
local footer_ns = vim.api.nvim_create_namespace("lazyagent_acp_footer")
local highlights_defined = false
local layout_autocmds_initialized = false
local first_visible_window
local replace_buffer_lines
local set_buffer_lines
local scroll_buffer_to_end
local transcript_line_count

local function ensure_highlights()
  if highlights_defined then
    return
  end
  highlights_defined = true

  local defs = {
    LazyAgentACPUserHeader = { default = true, fg = "#e0af68", bold = true },
    LazyAgentACPAssistantHeader = { default = true, fg = "#9ece6a", bold = true },
    LazyAgentACPThinkingHeader = { default = true, fg = "#bb9af7", bold = true },
    LazyAgentACPSystemHeader = { default = true, fg = "#7dcfff", bold = true },
    LazyAgentACPErrorHeader = { default = true, fg = "#f7768e", bold = true },
    LazyAgentACPPlanHeader = { default = true, fg = "#e0af68", bold = true },
    LazyAgentACPToolHeader = { default = true, fg = "#7aa2f7", bold = true },
    LazyAgentACPTerminalHeader = { default = true, fg = "#73daca", bold = true },
    LazyAgentACPBorder = { default = true, link = "FloatBorder" },
    LazyAgentACPFooterActive = { default = true, link = "DiagnosticInfo" },
    LazyAgentACPFooterWaiting = { default = true, link = "DiagnosticWarn" },
    LazyAgentACPFooterError = { default = true, link = "DiagnosticError" },
    LazyAgentACPFooterMuted = { default = true, link = "Comment" },
    LazyAgentACPFooterMeta = { default = true, link = "SpecialComment" },
  }

  for name, spec in pairs(defs) do
    pcall(vim.api.nvim_set_hl, 0, name, spec)
  end
end

local function session_for_agent(agent_name)
  return agent_name and state.sessions and state.sessions[agent_name] or nil
end

local function use_footer_window()
  return false
end

local function line_has_heading(line, heading)
  local needle = " " .. heading .. " "
  if line:find(needle, 1, true) then
    return true
  end
  local suffix = " " .. heading
  return line:sub(-#suffix) == suffix
end

local function section_style_for_line(line)
  if line_has_heading(line, "User") then
    return "LazyAgentACPUserHeader"
  end
  if line_has_heading(line, "Assistant") then
    return "LazyAgentACPAssistantHeader"
  end
  if line_has_heading(line, "Thinking") then
    return "LazyAgentACPThinkingHeader"
  end
  if line_has_heading(line, "System") then
    return "LazyAgentACPSystemHeader"
  end
  if line_has_heading(line, "Error") then
    return "LazyAgentACPErrorHeader"
  end
  if line_has_heading(line, "Plan") then
    return "LazyAgentACPPlanHeader"
  end
  if line_has_heading(line, "Terminal") then
    return "LazyAgentACPTerminalHeader"
  end
  if line_has_heading(line, "Tool") or line_has_heading(line, "Edited") then
    return "LazyAgentACPToolHeader"
  end
  return "LazyAgentACPBorder"
end

local function line_has_tail(line)
  return line_has_heading(line, "User") or line_has_heading(line, "Assistant")
end

local function strdisplaywidth(text)
  local ok, width = pcall(vim.fn.strdisplaywidth, text)
  return ok and width or #tostring(text or "")
end

local function tail_prefix(line)
  return (line:gsub("[%s─]+$", ""))
end

local function header_target_width(bufnr)
  local win = first_visible_window(bufnr)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return nil
  end
  return math.max(0, vim.api.nvim_win_get_width(win))
end

local function overlay_target_width(bufnr)
  local win = first_visible_window(bufnr)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return 80
  end
  return math.max(12, vim.api.nvim_win_get_width(win) - 2)
end

local function normalize_header_lines(bufnr, lines)
  local width = header_target_width(bufnr)
  if not width or width <= 0 then
    return lines, false
  end

  local changed = false
  local normalized = nil
  for idx, line in ipairs(lines) do
    if line:match("^─ ") and line_has_tail(line) then
      local prefix = tail_prefix(line)
      local prefix_width = strdisplaywidth(prefix)
      local tail_len = math.max(8, width - prefix_width - 1)
      local rebuilt = prefix .. " " .. string.rep("─", tail_len)
      if rebuilt ~= line then
        normalized = normalized or vim.deepcopy(lines)
        normalized[idx] = rebuilt
        changed = true
      end
    end
  end

  return normalized or lines, changed
end

local function decorate_transcript_range(bufnr, start_idx, end_idx)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  ensure_highlights()
  local transcript_stop = transcript_line_count(bufnr)
  local range_start = math.max(0, tonumber(start_idx) or 0)
  local range_stop = math.max(range_start, math.min(transcript_stop, tonumber(end_idx) or transcript_stop))
  if range_start >= range_stop then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, range_start, range_stop, false)
  local normalized, changed = normalize_header_lines(bufnr, lines)
  if changed then
    replace_buffer_lines(bufnr, range_start, range_stop, normalized)
    lines = normalized
  end

  vim.api.nvim_buf_clear_namespace(bufnr, transcript_ns, range_start, range_stop)
  for idx, line in ipairs(lines) do
    if line:match("^─ ") or line:match("^╭─ ") then
      local header_hl = section_style_for_line(line)
      vim.api.nvim_buf_add_highlight(bufnr, transcript_ns, header_hl, range_start + idx - 1, 0, -1)
    end
  end
end

local function decorate_buffer(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  vim.api.nvim_buf_clear_namespace(bufnr, transcript_ns, 0, -1)
  decorate_transcript_range(bufnr, 0, transcript_line_count(bufnr))
end

local function find_config_option(session, keys)
  if not session or type(session.acp_config_options) ~= "table" then
    return nil
  end

  keys = type(keys) == "table" and keys or { keys }
  for _, option in ipairs(session.acp_config_options) do
    if type(option) == "table" then
      local option_id = tostring(option.id or "")
      local category = tostring(option.category or "")
      local name = tostring(option.name or "")
      for _, key in ipairs(keys) do
        local expected = tostring(key or "")
        if expected ~= "" and (option_id == expected or category == expected or name == expected) then
          return option
        end
      end
    end
  end

  return nil
end

local function is_normal_window(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local ok, config = pcall(vim.api.nvim_win_get_config, win)
  return ok and config and config.relative == ""
end

local function resolve_anchor_window(win)
  if is_normal_window(win) then
    return win
  end
  local current = vim.api.nvim_get_current_win()
  if is_normal_window(current) then
    return current
  end
  return nil
end

local function to_bufnr(pane_id)
  local n = tonumber(pane_id)
  if n and vim.api.nvim_buf_is_valid(n) then
    return n
  end
  return nil
end

local function buffer_var(bufnr, name)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local ok, value = pcall(vim.api.nvim_buf_get_var, bufnr, name)
  return ok and value or nil
end

local function pane_id_for_bufnr(bufnr)
  return buffer_var(bufnr, "lazyagent_acp_pane_id") or bufnr
end

local function agent_name_for_bufnr(bufnr)
  return buffer_var(bufnr, "lazyagent_acp_agent")
end

local function pane_opts_for_bufnr(bufnr)
  return pane_config[tostring(pane_id_for_bufnr(bufnr))] or {}
end

local function should_follow_output(bufnr)
  return pane_opts_for_bufnr(bufnr).follow_output ~= false
end

local function set_follow_output(bufnr, enabled)
  local pane_id = tostring(pane_id_for_bufnr(bufnr))
  pane_config[pane_id] = vim.tbl_extend("force", pane_config[pane_id] or {}, {
    follow_output = enabled ~= false,
  })
end

local function set_window_size(win, size, is_vertical)
  local amount = tonumber(size)
  if not amount or amount <= 0 then
    return
  end
  if is_vertical then
    pcall(vim.api.nvim_win_set_width, win, math.max(10, amount))
  else
    pcall(vim.api.nvim_win_set_height, win, math.max(3, amount))
  end
end

local function apply_transcript_window_opts(win, is_vertical)
  pcall(function()
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].cursorline = false
    vim.wo[win].wrap = true
    vim.wo[win].signcolumn = "no"
    vim.wo[win].foldcolumn = "0"
    vim.wo[win].winfixwidth = is_vertical == true
    vim.wo[win].winfixheight = is_vertical ~= true
    vim.wo[win].scrolloff = 2
    vim.wo[win].statusline = ""
  end)
end

local function close_buffer_windows(bufnr)
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
end

first_visible_window = function(bufnr)
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(win) then
      return win
    end
  end
  return nil
end

set_buffer_lines = function(bufnr, lines)
  replace_buffer_lines(bufnr, 0, -1, lines)
end

replace_buffer_lines = function(bufnr, start_idx, end_idx, lines)
  local original_modifiable = vim.bo[bufnr].modifiable
  vim.bo[bufnr].modifiable = true
  pcall(vim.api.nvim_buf_set_lines, bufnr, start_idx, end_idx, false, lines)
  vim.bo[bufnr].modifiable = original_modifiable
end

local function ensure_layout_autocmds()
  if layout_autocmds_initialized then
    return
  end
  layout_autocmds_initialized = true

  local group = vim.api.nvim_create_augroup("LazyAgentACPLayout", { clear = true })
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized", "BufWinEnter" }, {
    group = group,
    callback = function()
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if buffer_var(bufnr, "lazyagent_acp_pane_id") ~= nil then
          pcall(decorate_buffer, bufnr)
          pcall(M.refresh_footer, bufnr)
          if should_follow_output(bufnr) then
            pcall(scroll_buffer_to_end, bufnr)
          end
        end
      end
    end,
  })
end

scroll_buffer_to_end = function(bufnr)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if line_count <= 0 then
    return
  end
  local last_line = vim.api.nvim_buf_get_lines(bufnr, line_count - 1, line_count, false)[1] or ""
  local row = math.max(1, line_count)
  local col = math.max(0, #last_line)
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_set_cursor, win, { row, col })
    end
  end
end

transcript_line_count = function(bufnr)
  local total = vim.api.nvim_buf_line_count(bufnr)
  local footer_lines = math.max(0, tonumber(footer_state[tostring(bufnr)]) or 0)
  return math.max(0, total - footer_lines)
end

local function transcript_lines(bufnr)
  local total = vim.api.nvim_buf_line_count(bufnr)
  local stop = transcript_line_count(bufnr)
  if total <= 0 or stop <= 0 then
    return {}
  end
  return vim.api.nvim_buf_get_lines(bufnr, 0, stop, false)
end

local function append_text_to_buffer(bufnr, text)
  if not text or text == "" or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local transcript_stop = transcript_line_count(bufnr)
  local total_lines = vim.api.nvim_buf_line_count(bufnr)
  local replace_start = transcript_stop
  local current_last = ""
  if transcript_stop > 0 then
    replace_start = transcript_stop - 1
    current_last = vim.api.nvim_buf_get_lines(bufnr, replace_start, transcript_stop, false)[1] or ""
  end

  local chunks = vim.split(text, "\n", { plain = true })
  local replacement = { current_last .. table.remove(chunks, 1) }
  vim.list_extend(replacement, chunks)

  replace_buffer_lines(bufnr, replace_start, total_lines, replacement)
  footer_state[tostring(bufnr)] = 0
  return replace_start
end

local function refresh_buffer_from_file(session)
  local bufnr = to_bufnr(session and session.pane_id)
  if not bufnr then
    return
  end

  session.view_state = session.view_state or {}
  if session.view_state.refresh_pending then
    return
  end
  session.view_state.refresh_pending = true

  vim.schedule(function()
    session.view_state.refresh_pending = false
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end

    local lines = {}
    if vim.fn.filereadable(session.transcript_path) == 1 then
      local ok, data = pcall(vim.fn.readfile, session.transcript_path)
      if ok and data then
        lines = data
      end
    end

    set_buffer_lines(bufnr, lines)
    decorate_buffer(bufnr)
    M.refresh_footer(bufnr)
    if should_follow_output(bufnr) then
      scroll_buffer_to_end(bufnr)
    end
  end)
end

local function queue_append(session, text)
  local bufnr = to_bufnr(session and session.pane_id)
  if not bufnr then
    return
  end

  session.view_state = session.view_state or {}
  session.view_state.pending_append = (session.view_state.pending_append or "") .. tostring(text or "")
  if session.view_state.append_pending then
    return
  end
  session.view_state.append_pending = true

  vim.schedule(function()
    session.view_state.append_pending = false
    if not vim.api.nvim_buf_is_valid(bufnr) then
      session.view_state.pending_append = ""
      return
    end
    local pending = session.view_state.pending_append or ""
    session.view_state.pending_append = ""
    if pending == "" then
      return
    end
    local changed_start = append_text_to_buffer(bufnr, pending)
    if changed_start ~= nil then
      decorate_transcript_range(bufnr, changed_start, transcript_line_count(bufnr))
    end
    M.refresh_footer(bufnr)
    if should_follow_output(bufnr) then
      scroll_buffer_to_end(bufnr)
    end
  end)
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
  local stat = vim.loop.fs_stat(path)
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
      if meta.copilotUsage and meta.copilotUsage ~= "" then
        return tostring(meta.copilotUsage)
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
    local frame_idx = math.floor(vim.loop.now() / 80) % #spinner_frames + 1
    return spinner_frames[frame_idx] .. " " .. (message ~= "" and message or "Thinking..."), "LazyAgentACPFooterActive"
  end

  if not session.acp_ready then
    return "◌ Connecting " .. provider_label(agent_name, session) .. "...", "LazyAgentACPFooterMuted"
  end

  return nil, nil
end

local function footer_context_segments(session)
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

  local command_count = type(session and session.acp_available_commands) == "table" and #session.acp_available_commands or 0
  if command_count > 0 then
    table.insert(segments, string.format("%d slash cmd%s", command_count, command_count == 1 and "" or "s"))
  end

  if session and session.acp_supports_embedded_context then
    table.insert(segments, "Embedded ctx")
  end

  return segments
end

local function footer_context_text(session)
  local context = footer_context_segments(session)
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

local function footer_render_lines(agent_name, session)
  local size = transcript_size_label(session)
  local provider = provider_label(agent_name, session)
  local context = footer_context_text(session)
  local status_text, status_hl = session_status(agent_name, session)
  local lines = {}
  local meta = {}

  if provider ~= "" then
    table.insert(meta, provider)
  end
  if size then
    table.insert(meta, size)
  end

  if status_text and status_text ~= "" then
    table.insert(lines, { text = " " .. status_text, hl = status_hl or "LazyAgentACPFooterMuted" })
  end

  if #meta > 0 or (context and context ~= "") then
    table.insert(lines, blank_footer_line())
    table.insert(lines, blank_footer_line())
  end

  if #meta > 0 then
    table.insert(lines, { text = " " .. table.concat(meta, "  "), hl = "LazyAgentACPFooterMuted" })
  end

  if context and context ~= "" then
    table.insert(lines, { text = " " .. context, hl = "LazyAgentACPFooterMeta" })
  end

  return lines
end

local function render_footer_lines(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return {}, {}
  end

  local agent_name = agent_name_for_bufnr(bufnr)
  if not agent_name or agent_name == "" then
    return {}, {}
  end

  local rendered = {}
  local highlights = {}
  for _, line in ipairs(footer_render_lines(agent_name, session_for_agent(agent_name))) do
    for _, wrapped in ipairs(wrap_footer_text(line.text or "", overlay_target_width(bufnr))) do
      table.insert(rendered, wrapped)
      table.insert(highlights, line.hl)
    end
  end
  return rendered, highlights
end

local function current_config_for_agent(agent_name, category)
  return select(1, current_config_details(session_for_agent(agent_name), { category }))
end

local function config_summary_for_agent(agent_name)
  local labels = {}
  local model = current_config_for_agent(agent_name, "model")
  if model and model ~= "" then
    table.insert(labels, model)
  end
  local mode = current_config_for_agent(agent_name, "mode")
  if mode and mode ~= "" then
    table.insert(labels, mode)
  end
  return table.concat(labels, " · ")
end

function M.statusline()
  return ""
end

function M.refresh_footer(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local footer_start = transcript_line_count(bufnr)
  local footer_lines, footer_hls = render_footer_lines(bufnr)
  footer_state[tostring(bufnr)] = 0
  replace_buffer_lines(bufnr, footer_start, -1, footer_lines)
  footer_state[tostring(bufnr)] = #footer_lines
  vim.api.nvim_buf_clear_namespace(bufnr, footer_ns, 0, -1)
  for idx, hl in ipairs(footer_hls) do
    if hl and hl ~= "" then
      vim.api.nvim_buf_add_highlight(bufnr, footer_ns, hl, footer_start + idx - 1, 0, -1)
    end
  end
end

function M.refresh_all_footers()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if buffer_var(bufnr, "lazyagent_acp_pane_id") ~= nil then
      M.refresh_footer(bufnr)
    end
  end
end

function M.refresh_agent_footers(agent_name)
  if not agent_name or agent_name == "" then
    return
  end
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if buffer_var(bufnr, "lazyagent_acp_pane_id") ~= nil
      and buffer_var(bufnr, "lazyagent_acp_agent") == agent_name
    then
      M.refresh_footer(bufnr)
    end
  end
end

function M.create_pane(args, on_split)
  ensure_layout_autocmds()
  local anchor_win = resolve_anchor_window(args.acp and args.acp.source_winid)
  if anchor_win then
    pcall(vim.api.nvim_set_current_win, anchor_win)
  end

  if args.is_vertical then
    vim.cmd("vsplit")
  else
    vim.cmd("split")
  end

  local win = vim.api.nvim_get_current_win()
  set_window_size(win, args.size, args.is_vertical)

  local bufnr = vim.api.nvim_create_buf(false, true)
  local agent_name = (args.acp or {}).agent_name or "agent"
  local safe_agent_name = agent_name:gsub("[^%w-_]+", "-")

  pcall(function()
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "hide"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].filetype = "markdown"
    vim.api.nvim_buf_set_name(bufnr, string.format("lazyagent://acp/%s-%d", safe_agent_name, bufnr))
    vim.b[bufnr].lazyagent_acp_pane_id = tostring(bufnr)
    vim.b[bufnr].lazyagent_acp_agent = agent_name
  end)
  pane_config[tostring(bufnr)] = vim.tbl_extend("force", pane_config[tostring(bufnr)] or {}, {
    source_winid = anchor_win,
    is_vertical = args.is_vertical == true,
    follow_output = true,
  })

  vim.api.nvim_win_set_buf(win, bufnr)
  apply_transcript_window_opts(win, args.is_vertical)

  local lines = {}
  if vim.fn.filereadable(args.transcript_path) == 1 then
    local ok, data = pcall(vim.fn.readfile, args.transcript_path)
    if ok and data then
      lines = data
    end
  end
  vim.bo[bufnr].modifiable = true
  pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  decorate_buffer(bufnr)
  M.refresh_footer(bufnr)

  if anchor_win and anchor_win ~= win then
    pcall(vim.api.nvim_set_current_win, anchor_win)
  end

  if on_split then
    vim.schedule(function()
      on_split(tostring(bufnr), { bufnr = bufnr, winid = win, source_winid = anchor_win })
    end)
  end
end

function M.on_session_created(session)
  local bufnr = to_bufnr(session and session.pane_id)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(function()
      vim.b[bufnr].lazyagent_acp_pane_id = tostring(session.pane_id)
      vim.b[bufnr].lazyagent_acp_agent = session.agent_name
    end)
    M.refresh_footer(bufnr)
  end
  refresh_buffer_from_file(session)
end

function M.on_transcript_updated(session, text, mode)
  if mode == "w" then
    refresh_buffer_from_file(session)
    return
  end
  queue_append(session, text)
end

function M.configure_pane(pane_id, opts)
  pane_config[tostring(pane_id)] = vim.tbl_extend("force", pane_config[tostring(pane_id)] or {}, opts or {})
  if pane_config[tostring(pane_id)].follow_output == nil then
    pane_config[tostring(pane_id)].follow_output = true
  end
  return true
end

function M.clear_pane_config(pane_id)
  pane_config[tostring(pane_id)] = nil
  return true
end

function M.pane_exists(pane_id)
  return to_bufnr(pane_id) ~= nil
end

function M.kill_pane(pane_id)
  local bufnr = to_bufnr(pane_id)
  if not bufnr then
    return false
  end
  close_buffer_windows(bufnr)
  footer_state[tostring(bufnr)] = nil
  pane_config[tostring(pane_id)] = nil
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  return true
end

function M.get_pane_info(pane_id, on_info)
  local bufnr = to_bufnr(pane_id)
  local info = nil
  if bufnr then
    local win = first_visible_window(bufnr)
    if win then
      info = {
        width = vim.api.nvim_win_get_width(win),
        height = vim.api.nvim_win_get_height(win),
      }
    end
  end
  if on_info then
    vim.schedule(function()
      on_info(info)
    end)
  end
  return info ~= nil
end

function M.break_pane(pane_id)
  local bufnr = to_bufnr(pane_id)
  if not bufnr then
    return false
  end
  close_buffer_windows(bufnr)
  return true
end

function M.break_pane_sync(pane_id)
  return M.break_pane(pane_id)
end

function M.join_pane(pane_id, size, is_vertical, on_done)
  ensure_layout_autocmds()
  local bufnr = to_bufnr(pane_id)
  if not bufnr then
    if on_done then
      vim.schedule(function()
        on_done(false)
      end)
    end
    return false
  end

  local pane_opts = pane_config[tostring(pane_id)] or {}
  local anchor_win = resolve_anchor_window(pane_opts.source_winid)
  local existing = first_visible_window(bufnr)
  if existing then
    pane_config[tostring(pane_id)] = vim.tbl_extend("force", pane_opts, {
      source_winid = anchor_win,
      is_vertical = is_vertical == true,
    })
    M.refresh_footer(bufnr)
    if on_done then
      vim.schedule(function()
        on_done(true)
      end)
    end
    return true
  end

  if anchor_win then
    pcall(vim.api.nvim_set_current_win, anchor_win)
  end

  if is_vertical then
    vim.cmd("vsplit")
  else
    vim.cmd("split")
  end
  local win = vim.api.nvim_get_current_win()
  set_window_size(win, size, is_vertical)
  vim.api.nvim_win_set_buf(win, bufnr)
  apply_transcript_window_opts(win, is_vertical)
  local ok, agent_name = pcall(vim.api.nvim_buf_get_var, bufnr, "lazyagent_acp_agent")
  pane_config[tostring(pane_id)] = vim.tbl_extend("force", pane_config[tostring(pane_id)] or {}, {
    source_winid = anchor_win,
    is_vertical = is_vertical == true,
    follow_output = pane_opts.follow_output ~= false,
  })
  M.refresh_footer(bufnr)

  if anchor_win and anchor_win ~= win then
    pcall(vim.api.nvim_set_current_win, anchor_win)
  end

  if on_done then
    vim.schedule(function()
      on_done(true)
    end)
  end
  return true
end

function M.copy_mode()
  return false
end

function M.scroll_up(pane_id)
  local bufnr = to_bufnr(pane_id)
  if not bufnr then
    return false
  end

  local line_count = math.max(1, vim.api.nvim_buf_line_count(bufnr))
  local scrolled = false
  set_follow_output(bufnr, false)
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_call, win, function()
        local height = math.max(1, vim.api.nvim_win_get_height(win))
        local step = math.max(1, math.floor(height / 2))
        local view = vim.fn.winsaveview()
        local new_topline = math.max(1, view.topline - step)
        local line_delta = new_topline - view.topline
        view.topline = new_topline
        view.lnum = math.max(1, math.min(line_count, view.lnum + line_delta))
        vim.fn.winrestview(view)
        scrolled = true
      end)
    end
  end
  return scrolled
end

function M.scroll_down(pane_id)
  local bufnr = to_bufnr(pane_id)
  if not bufnr then
    return false
  end

  local line_count = math.max(1, vim.api.nvim_buf_line_count(bufnr))
  local scrolled = false
  set_follow_output(bufnr, false)
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_call, win, function()
        local height = math.max(1, vim.api.nvim_win_get_height(win))
        local step = math.max(1, math.floor(height / 2))
        local view = vim.fn.winsaveview()
        local new_topline = math.max(1, math.min(line_count, view.topline + step))
        local line_delta = new_topline - view.topline
        view.topline = new_topline
        view.lnum = math.max(1, math.min(line_count, view.lnum + line_delta))
        vim.fn.winrestview(view)
        scrolled = true
      end)
    end
  end
  return scrolled
end

function M.resume_follow(pane_id)
  local bufnr = to_bufnr(pane_id)
  if not bufnr then
    return false
  end
  set_follow_output(bufnr, true)
  M.refresh_footer(bufnr)
  scroll_buffer_to_end(bufnr)
  return true
end

function M.cleanup_if_idle()
  return false
end

return M
