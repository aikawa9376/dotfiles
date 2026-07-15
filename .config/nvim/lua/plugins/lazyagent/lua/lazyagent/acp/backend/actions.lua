
local M = {}
local ContentBlocks = require("lazyagent.acp.content_blocks")
local ContextItem = require("lazyagent.acp.context_item")

function M.setup(deps)
  local state = deps.state
  local agent_logic = deps.agent_logic
  local local_commands = deps.local_commands
  local cache_logic = deps.cache_logic
  local summary_logic = deps.summary_logic
  local sanitize_filename_component = deps.sanitize_filename_component
  local file_uri = deps.file_uri
  local read_path_lines = deps.read_path_lines
  local reload_loaded_buffers_for_path = deps.reload_loaded_buffers_for_path
  local append_block = deps.append_block
  local render_tool_content = deps.render_tool_content
  local render_tool_raw_output = deps.render_tool_raw_output
  local extract_tool_paths = deps.extract_tool_paths
  local summarize_tool = deps.summarize_tool
  local normalize_tool_path = deps.normalize_tool_path
  local config_option_current_name = deps.config_option_current_name
  local config_option_kind = deps.config_option_kind
  local config_option_category = deps.config_option_category
  local config_option_description = deps.config_option_description
  local config_option_title = deps.config_option_title
  local show_config_picker_for_session = deps.show_config_picker_for_session
  local session_has_available_command = deps.session_has_available_command
  local buffer_root_for_session

  local module = {}
  local ACP_MARKDOWN_FILETYPE = "lazyagent_acp_markdown"

  local function hook_reload_enabled()
    return (((state.opts or {}).hooks or {}).reload_mode or "hook") ~= "watch"
  end

  local function session_source_bufnr(session)
    local bufnr = session and session.agent_cfg and (session.agent_cfg.source_bufnr or session.agent_cfg.origin_bufnr) or nil
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      return bufnr
    end
    return nil
  end

  local function apply_output_buffer_filetype(bufnr, filetype)
    local resolved = filetype or "markdown"
    if resolved == "markdown" then
      vim.bo[bufnr].filetype = ACP_MARKDOWN_FILETYPE
      pcall(vim.treesitter.start, bufnr, "markdown")
      return
    end
    vim.bo[bufnr].filetype = resolved
  end

local function read_text_ref(ref)
  if type(ref) ~= "table" or not ref.path or ref.path == "" or vim.fn.filereadable(ref.path) ~= 1 then
    return ""
  end
  local ok, lines = pcall(vim.fn.readfile, ref.path)
  if not ok or type(lines) ~= "table" then
    return ""
  end
  return table.concat(lines, "\n")
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

local function file_stat(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local loop = vim.uv or vim.loop
  return loop and loop.fs_stat(path) or nil
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

local function render_tool_timeline_detail(session, entry)
  local tool = entry and entry.tool or {}
  local lines = {
    "# ACP Tool Timeline",
    "",
    "ID: " .. tostring(entry and entry.toolCallId or ""),
    "Title: " .. tostring(entry and entry.title or tool.title or ""),
    "Heading: " .. tostring(entry and entry.heading or ""),
    "Status: " .. tostring(entry and entry.status or tool.status or ""),
  }
  if entry and entry.kind and entry.kind ~= "" then
    lines[#lines + 1] = "Kind: " .. tostring(entry.kind)
  end
  if entry and entry.summary and entry.summary ~= "" then
    lines[#lines + 1] = "Summary: " .. tostring(entry.summary)
  end
  local content_bytes = text_ref_size(entry and entry.rendered_content_ref, entry and entry.rendered_content)
  local raw_bytes = text_ref_size(entry and entry.rendered_raw_output_ref, entry and entry.rendered_raw_output)
  if content_bytes or raw_bytes then
    lines[#lines + 1] = string.format(
      "Output size: content=%s, raw=%s",
      format_bytes(content_bytes) or "none",
      format_bytes(raw_bytes) or "none"
    )
  end
  if entry and entry.pinned == true then
    lines[#lines + 1] = "Pinned: true"
  end
  if entry and entry.compacted == true then
    lines[#lines + 1] = "Compacted: true"
  end

  local paths = type(entry and entry.paths) == "table" and entry.paths or extract_tool_paths(tool)
  if #paths > 0 then
    lines[#lines + 1] = "Paths:"
    for _, path in ipairs(paths) do
      lines[#lines + 1] = "- " .. path
    end
  end

  local body = tostring(entry and entry.rendered_content or "")
  if body == "" then
    body = read_text_ref(entry and entry.rendered_content_ref)
  end
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
    raw_output = read_text_ref(entry and entry.rendered_raw_output_ref)
  end
  if raw_output == "" then
    raw_output = render_tool_raw_output(tool.rawOutput)
  end
  if raw_output ~= "" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Raw output:"
    vim.list_extend(lines, vim.split(raw_output, "\n", { plain = true }))
  end

  if entry and entry.compacted == true and body == "" and raw_output == "" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Output was compacted to reduce memory. Use :LazyAgentACPFullTranscript or :LazyAgentACPRawTranscript for the full transcript."
    if session and session.transcript_path and session.transcript_path ~= "" then
      lines[#lines + 1] = "Transcript: " .. session.transcript_path
    end
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
  vim.bo[buf].undolevels = -1
  vim.bo[buf].modifiable = true
  apply_output_buffer_filetype(buf, filetype)
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
    render_tool_timeline_detail(session, entry)
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

local reports = require("lazyagent.acp.backend.reports").setup({
  local_commands = local_commands,
  sanitize_filename_component = sanitize_filename_component,
  open_report_buffer = open_report_buffer,
})
local show_doctor_for_session = reports.show_doctor_for_session
local show_context_budget_for_session = reports.show_context_budget_for_session
local show_tool_review_for_session = reports.show_tool_review_for_session

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

  if command.name == "auth" then
    session.client:request_authentication(function(_, err)
      append_block(session, "System", err and ("Authentication failed: " .. tostring(err.message or err)) or "Authentication completed")
    end)
    return true
  end

  if command.name == "logout" then
    session.client:logout(function(_, err)
      append_block(session, "System", err and ("Logout failed: " .. tostring(err.message or err)) or "Logged out from ACP agent")
    end)
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

  if command.name == "doctor" then
    show_doctor_for_session(session)
    return true
  end

  if command.name == "context" then
    show_context_budget_for_session(session)
    return true
  end

  if command.name == "tools" then
    show_tool_review_for_session(session)
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
      if hook_reload_enabled() then
        reload_loaded_buffers_for_path(path)
      end
      if hook_reload_enabled() and ((state.opts or {}).hooks or {}).open_on_edit == true then
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

  if core == "diagnostics" then
    local item, item_err = ContextItem.diagnostics(session_source_bufnr(session))
    if not item then
      return {
        block = { type = "text", text = "[diagnostics unavailable: " .. tostring(item_err) .. "]" },
        trailing = trailing,
      }
    end
    return {
      block = ContextItem.lower(item, {
        embedded_context = session.prompt_supports_embedded_context == true,
      }),
      trailing = trailing,
    }
  end

  if core == "branch-diff" then
    local item, item_err = ContextItem.branch_diff(buffer_root_for_session(session))
    if not item then
      return {
        block = { type = "text", text = "[branch diff unavailable: " .. tostring(item_err) .. "]" },
        trailing = trailing,
      }
    end
    return {
      block = ContextItem.lower(item, {
        embedded_context = session.prompt_supports_embedded_context == true,
      }),
      trailing = trailing,
    }
  end

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
  local is_media = false
  local lines
  for _, candidate in ipairs(candidates) do
    local expanded = vim.fn.fnamemodify(candidate, ":p")
    if vim.fn.isdirectory(expanded) == 1 then
      abs_path = expanded
      is_directory = true
      break
    end
    if ContentBlocks.media_kind(expanded) and vim.fn.filereadable(expanded) == 1 then
      abs_path = expanded
      is_media = true
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

  local display = path_part
  local block
  local context_item
  if is_media then
    context_item = ContextItem.media({ path = abs_path, display = display })
    local media_err
    block, media_err = ContextItem.lower(context_item, {
      image = session.prompt_supports_image == true,
      audio = session.prompt_supports_audio == true,
    })
    if not block then
      block = {
        type = "text",
        text = "[media omitted: " .. tostring(media_err or "failed to read media") .. "]",
      }
    end
  elseif is_directory then
    context_item = ContextItem.directory({ path = abs_path, display = display })
    block = ContextItem.lower(context_item, {
      embedded_context = session.prompt_supports_embedded_context == true,
    })
  else
    context_item = ContextItem.file({
      path = abs_path,
      display = display,
      lines = lines or {},
      start_line = line_start,
      end_line = line_end,
      column = column,
    })
    block = ContextItem.lower(context_item, {
      embedded_context = session.prompt_supports_embedded_context == true,
    })
  end

  return {
    block = block,
    note = context_item and context_item.note or nil,
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

local function normalize_text_after_context_block(text)
  text = tostring(text or "")
  if text == "" or text:match("^%s*$") then
    return ""
  end
  if not text:match("^%s") then
    return text
  end
  if text:match("^\n\n") then
    return text
  end
  if text:match("^\n") then
    return "\n\n" .. text:gsub("^\n[ \t]*", "")
  end
  return "\n\n" .. text:gsub("^[ \t]+", "")
end

local function build_prompt_blocks(session, text)
  local blocks = {}
  local cursor = 1
  local after_context_block = false
  local function push_prompt_text(segment)
    if after_context_block then
      segment = normalize_text_after_context_block(segment)
      if segment == "" then
        return
      end
      after_context_block = false
    end
    push_text_block(blocks, segment)
  end

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
      push_prompt_text(text:sub(cursor, start_idx - 1))
      if ref.note then
        push_text_block(blocks, ref.note)
      end
      table.insert(blocks, ref.block)
      after_context_block = true
      if ref.trailing and ref.trailing ~= "" then
        push_prompt_text(ref.trailing)
      end
      cursor = end_idx + 1
    end
  end

  push_prompt_text(text:sub(cursor))
  if #blocks == 0 then
    push_text_block(blocks, text)
  end
  return blocks
end

  module.open_tool_timeline_buffer = open_tool_timeline_buffer
  module.show_tool_timeline_for_session = show_tool_timeline_for_session
  module.show_capabilities_for_session = show_capabilities_for_session
  module.show_doctor_for_session = show_doctor_for_session
  module.show_context_budget_for_session = show_context_budget_for_session
  module.show_tool_review_for_session = show_tool_review_for_session
  module.show_resource_browser_for_session = show_resource_browser_for_session
  module.render_permission_preview = render_permission_preview
  module.handle_local_slash_command = handle_local_slash_command
  module.maybe_call_mcp_tool = maybe_call_mcp_tool
  module.maybe_sync_acp_edit_targets = maybe_sync_acp_edit_targets
  module.build_prompt_blocks = build_prompt_blocks

  return module
end

return M
