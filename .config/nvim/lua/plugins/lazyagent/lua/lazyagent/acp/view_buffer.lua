local M = {}

local agent_logic = require("lazyagent.logic.agent")
local image_paste = require("lazyagent.logic.image_paste")
local state = require("lazyagent.logic.state")
local view_diff = require("lazyagent.acp.view_diff")
local view_footer = require("lazyagent.acp.view_footer")
local pane_config = {}
local pane_buffers = {}
local transcript_read_handlers = {}
local next_pane_seq = 0
local transcript_ns = vim.api.nvim_create_namespace("lazyagent_acp_transcript")
local footer_ns = vim.api.nvim_create_namespace("lazyagent_acp_footer")
local diff_ns = vim.api.nvim_create_namespace("lazyagent_acp_diff")
local highlights_defined = false
local TRANSCRIPT_TRUNCATED_MARKER = "... earlier transcript omitted from buffer ..."
local FOLLOW_SCROLL_OFF = 0
local DEFAULT_SCROLL_OFF = 2
local ACP_TRANSCRIPT_FILETYPE = "lazyagent_acp"
local ACP_PIN_ICON = "󰐃"
local APPEND_BATCH_MS = 60
local MARKDOWN_RENDER_BATCH_MS = 120
local DECORATE_PREFETCH_MARGIN = 80
local DECORATE_SYNC_LINE_LIMIT = 600
local DECORATE_CHUNK_SIZE = 400
local first_visible_window
local replace_buffer_lines
local set_buffer_lines
local scroll_buffer_to_end
local transcript_max_lines
local transcript_line_count
local refresh_buffer_layout
local refresh_buffer_from_path
local layout_entry
local buffer_is_visible
local set_window_size
local diff_view
local footer_view
local pinned_section_rows
local cached_transcript_sections
local invalidate_transcript_section_cache
local pinned_rows_for_buffer
local transcript_source_lines
local pane_id_for_bufnr
local agent_name_for_bufnr
local pane_opts_for_bufnr
local resolve_anchor_window
local read_transcript_lines
local fancy_mode_enabled
local custom_background_groups = {}
local layout_state = {}
local suppress_transcript_window_refresh = false
local dedicated_transcript_windows = {}
local redirecting_transcript_windows = {}
local ACP_WINDOW_OPTIONS = {
  "number",
  "relativenumber",
  "cursorline",
  "wrap",
  "linebreak",
  "breakindent",
  "signcolumn",
  "statuscolumn",
  "foldcolumn",
  "foldenable",
  "foldmethod",
  "foldexpr",
  "winfixwidth",
  "winfixheight",
  "scrolloff",
  "smoothscroll",
  "statusline",
  "eventignorewin",
  "fillchars",
  "winhighlight",
}

local function close_timer(timer)
  if not timer then
    return
  end
  pcall(function() timer:stop() end)
  pcall(function() timer:close() end)
end

local function strdisplaywidth(text)
  local ok, width = pcall(vim.fn.strdisplaywidth, text)
  return ok and width or #tostring(text or "")
end

local request_buffer_redraw_impl
local function request_buffer_redraw(bufnr)
  return request_buffer_redraw_impl and request_buffer_redraw_impl(bufnr)
end

local function remove_list_value(list, value)
  if type(list) ~= "table" then
    return
  end
  for idx = #list, 1, -1 do
    if list[idx] == value then
      table.remove(list, idx)
    end
  end
end

local function cleanup_render_markdown_decorator(decorator, ns, bufnr)
  if type(decorator) ~= "table" then
    return
  end

  local marks = type(decorator.get) == "function" and decorator:get() or decorator.marks
  if vim.api.nvim_buf_is_valid(bufnr) and type(marks) == "table" then
    for _, mark in ipairs(marks) do
      if type(mark) == "table" and type(mark.hide) == "function" then
        pcall(mark.hide, mark, ns, bufnr)
      end
    end
  end

  decorator.marks = {}
  decorator.tick = nil
  decorator.running = false

  local timer = decorator.timer
  if timer then
    pcall(function() timer:stop() end)
    pcall(function() timer:close() end)
    decorator.timer = nil
  end
end

local function prune_invalid_render_markdown_state(manager, render_state, ui)
  if type(manager) == "table" and type(manager.buffers) == "table" then
    for idx = #manager.buffers, 1, -1 do
      local tracked = manager.buffers[idx]
      if not tracked or not vim.api.nvim_buf_is_valid(tracked) then
        table.remove(manager.buffers, idx)
      end
    end
  end

  if type(render_state) == "table" and type(render_state.cache) == "table" then
    for tracked, _ in pairs(render_state.cache) do
      if not tracked or not vim.api.nvim_buf_is_valid(tracked) then
        render_state.cache[tracked] = nil
      end
    end
  end

  if type(ui) == "table" and type(ui.cache) == "table" then
    for tracked, _ in pairs(ui.cache) do
      if not tracked or not vim.api.nvim_buf_is_valid(tracked) then
        cleanup_render_markdown_decorator(ui.cache[tracked], ui.ns, tracked)
        ui.cache[tracked] = nil
      end
    end
  end
end

local function cleanup_external_markdown_rendering(bufnr)
  if not bufnr then
    return
  end

  local is_valid = vim.api.nvim_buf_is_valid(bufnr)
  if is_valid then
    pcall(vim.treesitter.stop, bufnr)
  end

  local ok_manager, manager = pcall(require, "render-markdown.core.manager")
  if ok_manager and type(manager) == "table" then
    remove_list_value(manager.buffers, bufnr)
  end

  local ok_state, render_state = pcall(require, "render-markdown.state")
  if ok_state and type(render_state) == "table" and type(render_state.cache) == "table" then
    render_state.cache[bufnr] = nil
  end

  local ok_ui, ui = pcall(require, "render-markdown.core.ui")
  if ok_ui and type(ui) == "table" then
    if is_valid and ui.ns then
      pcall(vim.api.nvim_buf_clear_namespace, bufnr, ui.ns, 0, -1)
    end
    if type(ui.cache) == "table" then
      cleanup_render_markdown_decorator(ui.cache[bufnr], ui.ns, bufnr)
      ui.cache[bufnr] = nil
    end
  end

  if type(layout_entry) == "function" and is_valid then
    local entry = layout_entry(bufnr)
    entry.render_markdown_attached = nil
  end

  prune_invalid_render_markdown_state(
    ok_manager and manager or nil,
    ok_state and render_state or nil,
    ok_ui and ui or nil
  )
end

local function cleanup_markdown_rendering(bufnr)
  if not bufnr then
    return
  end

  local is_valid = vim.api.nvim_buf_is_valid(bufnr)
  if type(layout_entry) == "function" and is_valid then
    local entry = layout_entry(bufnr)
    close_timer(entry.markdown_render_timer)
    entry.markdown_render_timer = nil
    entry.markdown_render_pending = nil
    entry.markdown_render_token = nil
    entry.render_markdown_attached = nil
  end

  cleanup_external_markdown_rendering(bufnr)

  if is_valid then
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, transcript_ns, 0, -1)
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, footer_ns, 0, -1)
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, diff_ns, 0, -1)
  end
end

local function is_metadata_popup_buffer(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  local ok, value = pcall(vim.api.nvim_buf_get_var, bufnr, "lazyagent_acp_metadata_popup")
  return ok and value == true
end

local function ensure_highlights()
  if highlights_defined then
    return
  end
  highlights_defined = true

  local defs = {
    FugitiveExtAdd = { default = true, bg = "#23384C" },
    FugitiveExtDelete = { default = true, bg = "#321e1e" },
    FugitiveExtAddText = { default = true, bg = "#005f5f" },
    FugitiveExtDeleteText = { default = true, bg = "#8c3b40" },
    LazyAgentACPUserHeader = { default = true, fg = "#e0af68", bold = true },
    LazyAgentACPAssistantHeader = { default = true, fg = "#9ece6a", bold = true },
    LazyAgentACPThinkingHeader = { default = true, fg = "#bb9af7", bold = true },
    LazyAgentACPSystemHeader = { default = true, fg = "#7dcfff", bold = true },
    LazyAgentACPErrorHeader = { default = true, fg = "#f7768e", bold = true },
    LazyAgentACPPlanHeader = { default = true, fg = "#e0af68", bold = true },
    LazyAgentACPToolHeader = { default = true, fg = "#7aa2f7", bold = true },
    LazyAgentACPTerminalHeader = { default = true, fg = "#73daca", bold = true },
    LazyAgentACPPinIcon = { default = true, fg = "#f7768e", bold = true },
    LazyAgentACPBorder = { default = true, link = "FloatBorder" },
    LazyAgentACPFooterActive = { default = true, link = "DiagnosticInfo" },
    LazyAgentACPFooterWaiting = { default = true, link = "DiagnosticWarn" },
    LazyAgentACPFooterError = { default = true, link = "DiagnosticError" },
    LazyAgentACPFooterMuted = { default = true, link = "Comment" },
    LazyAgentACPFooterMeta = { default = true, link = "SpecialComment" },
    LazyAgentACPCardTitle = { default = true, link = "Title" },
    LazyAgentACPCardField = { default = true, link = "Identifier" },
    LazyAgentACPDiffDelete = { default = true, link = "FugitiveExtDelete" },
    LazyAgentACPDiffAdd = { default = true, link = "FugitiveExtAdd" },
    LazyAgentACPDiffDeleteWord = { default = true, link = "FugitiveExtDeleteText" },
    LazyAgentACPDiffAddWord = { default = true, link = "FugitiveExtAddText" },
  }

  for name, spec in pairs(defs) do
    pcall(vim.api.nvim_set_hl, 0, name, spec)
  end
end

local function refresh_markdown_rendering(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local ft = vim.bo[bufnr].filetype
  if ft ~= ACP_TRANSCRIPT_FILETYPE and ft ~= "lazyagent" then
    return
  end

  local wins = vim.fn.win_findbuf(bufnr)
  if #wins == 0 or (transcript_line_count and transcript_line_count(bufnr) == 0) then
    cleanup_markdown_rendering(bufnr)
    return
  end

  local entry = type(layout_entry) == "function" and layout_entry(bufnr) or nil
  if not entry or entry.render_markdown_attached ~= true then
    pcall(vim.treesitter.start, bufnr, "markdown")
  end

  local ok_manager, manager = pcall(require, "render-markdown.core.manager")
  if ok_manager and type(manager.attach) == "function" then
    if not entry or entry.render_markdown_attached ~= true then
      pcall(manager.attach, bufnr)
      if entry then
        entry.render_markdown_attached = true
      end
    end
  end

  local ok_ui, ui = pcall(require, "render-markdown.core.ui")
  if ok_ui and type(ui.update) == "function" then
    pcall(ui.update, bufnr, wins[1], "LazyAgentACPUpdate", false)
  end

  image_paste.refresh_buffer_previews(bufnr)
  request_buffer_redraw(bufnr)
end

local function queue_markdown_rendering(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if buffer_is_visible and not buffer_is_visible(bufnr) then
    return
  end

  local entry = layout_entry(bufnr)
  local opts = pane_opts_for_bufnr and pane_opts_for_bufnr(bufnr) or {}
  local debounce_ms = tonumber(opts.render_markdown_debounce_ms)
    or tonumber((((state.opts or {}).acp or {}).render_markdown_debounce_ms))
    or MARKDOWN_RENDER_BATCH_MS
  debounce_ms = math.max(0, math.floor(tonumber(debounce_ms) or MARKDOWN_RENDER_BATCH_MS))
  if debounce_ms == 0 then
    return
  end

  entry.markdown_render_pending = true

  close_timer(entry.markdown_render_timer)
  entry.markdown_render_timer = nil

  local token = {}
  entry.markdown_render_token = token

  local function run()
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    local current_entry = layout_state[tostring(bufnr)]
    if type(current_entry) ~= "table" or current_entry.markdown_render_token ~= token then
      return
    end
    current_entry.markdown_render_pending = false
    current_entry.markdown_render_token = nil
    current_entry.markdown_render_timer = nil
    if buffer_is_visible and not buffer_is_visible(bufnr) then
      return
    end
    refresh_markdown_rendering(bufnr)
  end

  local uv = vim.uv or vim.loop
  if uv and type(uv.new_timer) == "function" then
    local timer = uv.new_timer()
    entry.markdown_render_timer = timer
    timer:start(debounce_ms, 0, vim.schedule_wrap(function()
      close_timer(timer)
      run()
    end))
    return
  end

  if type(vim.defer_fn) == "function" then
    vim.defer_fn(run, debounce_ms)
  else
    vim.schedule(run)
  end
end

local function session_for_agent(agent_name)
  return agent_name and state.sessions and state.sessions[agent_name] or nil
end

local view_sections = require("lazyagent.acp.view_buffer.sections")
local line_has_heading = view_sections.line_has_heading
local replace_heading_token = view_sections.replace_heading_token
local section_style_for_line = view_sections.section_style_for_line
local line_has_tail = view_sections.line_has_tail
local is_markdown_fence = view_sections.is_markdown_fence
local code_block_target_row = view_sections.code_block_target_row
local FANCY_SECTION_LABELS = view_sections.FANCY_SECTION_LABELS
local FANCY_POPUP_MARKDOWN_TITLES = view_sections.FANCY_POPUP_MARKDOWN_TITLES
local FANCY_POPUP_SECTION_HEADINGS = view_sections.FANCY_POPUP_SECTION_HEADINGS
local jump_window_to_row = view_sections.jump_window_to_row
local section_heading_for_line = view_sections.section_heading_for_line
local collect_transcript_sections = view_sections.collect_transcript_sections
local balance_unclosed_markdown_fences = view_sections.balance_unclosed_markdown_fences
local append_crosses_unclosed_markdown_fence = view_sections.append_crosses_unclosed_markdown_fence
local trailing_section_has_open_markdown_fence = view_sections.trailing_section_has_open_markdown_fence

local function backend_for_agent(agent_name)
  local session = session_for_agent(agent_name)
  local backend_name = session and session.backend or nil
  if not backend_name or backend_name == "" then
    return nil
  end
  return state.backends and state.backends[backend_name] or nil
end

local function runtime_conversation_timeline(bufnr)
  local agent_name = agent_name_for_bufnr(bufnr)
  local session = session_for_agent(agent_name)
  if session and type(session.acp_conversation_timeline) == "table" then
    return session.acp_conversation_timeline
  end
  local backend = backend_for_agent(agent_name)
  if backend and type(backend.get_conversation_timeline) == "function" then
    return backend.get_conversation_timeline(pane_id_for_bufnr(bufnr))
  end
  return {}
end

local function runtime_tool_timeline(bufnr)
  local agent_name = agent_name_for_bufnr(bufnr)
  local session = session_for_agent(agent_name)
  if session and type(session.acp_tool_timeline) == "table" then
    return session.acp_tool_timeline
  end
  return {}
end

local function changedtick(bufnr)
  local ok, tick = pcall(vim.api.nvim_buf_get_changedtick, bufnr)
  return ok and tick or 0
end

local function items_for_sections(bufnr, sections)
  local entry = layout_entry(bufnr)
  local items = type(entry.transcript_section_items) == "table" and entry.transcript_section_items or nil
  if type(items) == "table" and #items == #sections then
    return items
  end

  items = {}
  local timeline = runtime_conversation_timeline(bufnr)
  local offset = math.max(#timeline - #sections, 0)
  for idx = 1, #sections do
    items[idx] = timeline[offset + idx]
  end
  return items
end

cached_transcript_sections = function(bufnr, kind, lines)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return {}
  end

  kind = kind == "display" and "display" or "source"
  local entry = layout_entry(bufnr)
  local key = kind == "display" and "transcript_display_sections_cache" or "transcript_source_sections_cache"
  local stop = transcript_line_count(bufnr)
  local tick = changedtick(bufnr)
  local cache = entry[key]
  if type(cache) == "table" and cache.tick == tick and cache.stop == stop then
    return cache.sections or {}
  end

  if type(lines) ~= "table" then
    lines = kind == "display"
        and vim.api.nvim_buf_get_lines(bufnr, 0, stop, false)
      or transcript_source_lines(bufnr, 0, stop)
  end
  local sections = collect_transcript_sections(lines)
  entry[key] = {
    tick = tick,
    stop = stop,
    sections = sections,
  }
  return sections
end

invalidate_transcript_section_cache = function(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local entry = layout_entry(bufnr)
  entry.transcript_source_sections_cache = nil
  entry.transcript_display_sections_cache = nil
end

pinned_rows_for_buffer = function(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return {}
  end

  local entry = layout_entry(bufnr)
  local display_meta = type(entry.transcript_display_meta) == "table" and entry.transcript_display_meta or {}
  if type(display_meta.pinned_rows) == "table" then
    return display_meta.pinned_rows
  end

  local sections = cached_transcript_sections(bufnr, "source")
  local items = items_for_sections(bufnr, sections)
  local pinned_rows = {}
  for idx, section in ipairs(sections) do
    if type(items[idx]) == "table" and items[idx].pinned == true then
      pinned_rows[section.start_row] = true
    end
  end
  display_meta.pinned_rows = pinned_rows
  entry.transcript_display_meta = display_meta
  return pinned_rows
end

local function visible_conversation_context(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local stop = transcript_line_count(bufnr)
  local lines = transcript_source_lines(bufnr, 0, stop)
  local sections = cached_transcript_sections(bufnr, "source", lines)
  if #sections == 0 then
    return {
      lines = lines,
      sections = sections,
      items = {},
      index = nil,
      section = nil,
      item = nil,
    }
  end

  local items = items_for_sections(bufnr, sections)

  local row = vim.api.nvim_win_get_cursor(vim.api.nvim_get_current_win())[1]
  local index = #sections
  for idx, section in ipairs(sections) do
    if row < section.start_row then
      index = math.max(1, idx - 1)
      break
    end
    if row >= section.start_row and row <= section.end_row then
      index = idx
      break
    end
  end

  return {
    lines = lines,
    sections = sections,
    items = items,
    index = index,
    section = sections[index],
    item = items[index],
  }
end

local function current_display_conversation_context(bufnr, win)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  if not win or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= bufnr then
    return nil
  end

  local stop = transcript_line_count(bufnr)
  local display_lines = vim.api.nvim_buf_get_lines(bufnr, 0, stop, false)
  local display_sections = cached_transcript_sections(bufnr, "display", display_lines)
  if #display_sections == 0 then
    return nil
  end

  local row = vim.api.nvim_win_get_cursor(win)[1]
  local index = nil
  for idx, section in ipairs(display_sections) do
    if row >= section.start_row and row <= section.end_row then
      index = idx
      break
    end
    if row < section.start_row then
      index = math.max(1, idx - 1)
      break
    end
  end
  index = index or #display_sections

  local entry = layout_entry(bufnr)
  local source_lines = type(entry.metadata_source_lines) == "table" and vim.deepcopy(entry.metadata_source_lines)
    or display_lines
  local source_sections = collect_transcript_sections(source_lines)
  local source_section = source_sections[index] or display_sections[index]
  local items = items_for_sections(bufnr, #source_sections > 0 and source_sections or display_sections)

  return {
    lines = source_lines,
    sections = source_sections,
    display_lines = display_lines,
    display_sections = display_sections,
    items = items,
    index = index,
    section = source_section,
    display_section = display_sections[index],
    item = items[index],
  }
end

local function section_text(lines, section)
  if type(lines) ~= "table" or type(section) ~= "table" then
    return ""
  end
  local chunk = {}
  for row = section.start_row, section.end_row do
    chunk[#chunk + 1] = lines[row] or ""
  end
  while #chunk > 0 and chunk[#chunk] == "" do
    table.remove(chunk)
  end
  return table.concat(chunk, "\n")
end

local function section_body_text(lines, section)
  if type(lines) ~= "table" or type(section) ~= "table" then
    return ""
  end
  local chunk = {}
  for row = (section.start_row or 0) + 1, section.end_row or 0 do
    local text = tostring(lines[row] or "")
    if text:sub(1, 1) == " " then
      text = text:sub(2)
    end
    chunk[#chunk + 1] = text
  end
  while #chunk > 0 and chunk[#chunk] == "" do
    table.remove(chunk)
  end
  return table.concat(chunk, "\n")
end

local function normalize_popup_text(text)
  local lines = vim.split(tostring(text or ""), "\n", { plain = true })
  for idx, line in ipairs(lines) do
    if line:sub(1, 1) == " " then
      lines[idx] = line:sub(2)
    end
  end
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end
  return table.concat(lines, "\n")
end

local function text_looks_like_transcript(text)
  text = tostring(text or "")
  if text == "" then
    return false
  end

  local heading_count = 0
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    if line == TRANSCRIPT_TRUNCATED_MARKER or section_heading_for_line(line) then
      heading_count = heading_count + 1
      if heading_count >= 2 then
        return true
      end
    end
  end

  return false
end

local function copy_to_clipboard(text, label)
  text = tostring(text or "")
  if text == "" then
    vim.notify("Nothing to copy", vim.log.levels.INFO)
    return
  end
  vim.fn.setreg('"', text)
  pcall(vim.fn.setreg, "+", text)
  vim.notify((label or "Copied") .. " to clipboard", vim.log.levels.INFO)
end

local view_actions = require("lazyagent.acp.view_buffer.actions").new({
  runtime_conversation_timeline = runtime_conversation_timeline,
  runtime_tool_timeline = runtime_tool_timeline,
  visible_conversation_context = visible_conversation_context,
  current_display_conversation_context = current_display_conversation_context,
  section_text = section_text,
  section_body_text = section_body_text,
  normalize_popup_text = normalize_popup_text,
  text_looks_like_transcript = text_looks_like_transcript,
  copy_to_clipboard = copy_to_clipboard,
  backend_for_agent = backend_for_agent,
  agent_name_for_bufnr = function(bufnr)
    return agent_name_for_bufnr(bufnr)
  end,
  session_for_bufnr = function(bufnr)
    return session_for_agent(agent_name_for_bufnr(bufnr))
  end,
  pane_id_for_bufnr = function(bufnr)
    return pane_id_for_bufnr(bufnr)
  end,
  jump_window_to_row = jump_window_to_row,
  quickfix_open_window_for_bufnr = function(bufnr)
    local pane_opts = pane_opts_for_bufnr(bufnr)
    local anchor = resolve_anchor_window(pane_opts and pane_opts.source_winid)
    if anchor and vim.api.nvim_win_is_valid(anchor) then
      return anchor
    end
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_is_valid(win) then
        local target_buf = vim.api.nvim_win_get_buf(win)
        local bt = vim.bo[target_buf].buftype
        if bt == "" or bt == "acwrite" then
          return win
        end
      end
    end
    return nil
  end,
  cleanup_markdown_rendering = cleanup_markdown_rendering,
  refresh_buffer_from_path = function(...)
    return refresh_buffer_from_path(...)
  end,
  read_transcript_lines = function(...)
    return read_transcript_lines(...)
  end,
  fancy_mode_enabled = function(bufnr)
    return fancy_mode_enabled(bufnr)
  end,
  dedicated_transcript_windows = dedicated_transcript_windows,
  acp_transcript_filetype = ACP_TRANSCRIPT_FILETYPE,
  layout_entry = function(bufnr)
    return layout_entry(bufnr)
  end,
  strdisplaywidth = strdisplaywidth,
  diff_view = function()
    return diff_view
  end,
  fancy_popup_markdown_titles = FANCY_POPUP_MARKDOWN_TITLES,
  fancy_popup_section_headings = FANCY_POPUP_SECTION_HEADINGS,
})
local show_action_menu = view_actions.show_action_menu
local show_metadata_popup = view_actions.show_metadata_popup

local view_tables = require("lazyagent.acp.view_buffer.tables").new({
  is_markdown_fence = is_markdown_fence,
})
local split_markdown_table_cells = view_tables.split_markdown_table_cells
local is_markdown_table_separator = view_tables.is_markdown_table_separator
local transform_markdown_tables = view_tables.transform_markdown_tables
local trailing_markdown_table_context = view_tables.trailing_markdown_table_context

local view_render = require("lazyagent.acp.view_buffer.render").new({
  section_heading_for_line = section_heading_for_line,
  replace_heading_token = replace_heading_token,
  fancy_section_labels = FANCY_SECTION_LABELS,
  first_visible_window = function(bufnr)
    return first_visible_window(bufnr)
  end,
  fancy_mode_enabled = function(bufnr)
    return fancy_mode_enabled(bufnr)
  end,
  strdisplaywidth = strdisplaywidth,
  layout_entry = function(bufnr)
    return layout_entry(bufnr)
  end,
  transcript_line_count = function(bufnr)
    return transcript_line_count(bufnr)
  end,
  replace_buffer_lines = function(...)
    return replace_buffer_lines(...)
  end,
  buffer_is_visible = function(bufnr)
    return buffer_is_visible(bufnr)
  end,
  pinned_section_rows = function(...)
    return pinned_section_rows(...)
  end,
  pinned_rows_for_buffer = function(bufnr)
    return pinned_rows_for_buffer(bufnr)
  end,
  line_has_tail = line_has_tail,
  section_style_for_line = section_style_for_line,
  diff_view = function()
    return diff_view
  end,
  transcript_ns = transcript_ns,
  acp_pin_icon = ACP_PIN_ICON,
  decorate_prefetch_margin = DECORATE_PREFETCH_MARGIN,
  decorate_sync_line_limit = DECORATE_SYNC_LINE_LIMIT,
  decorate_chunk_size = DECORATE_CHUNK_SIZE,
  ensure_highlights = ensure_highlights,
})
local header_target_width = view_render.header_target_width
local overlay_target_width = view_render.overlay_target_width
transcript_source_lines = view_render.transcript_source_lines
local normalize_transcript_display = view_render.normalize_transcript_display
local decorate_transcript_range = view_render.decorate_transcript_range
local decorate_buffer = view_render.decorate_buffer

local view_windowing = require("lazyagent.acp.view_buffer.windowing").new({
  api = M,
  pane_config = pane_config,
  pane_buffers = pane_buffers,
  layout_state = layout_state,
  dedicated_transcript_windows = dedicated_transcript_windows,
  redirecting_transcript_windows = redirecting_transcript_windows,
  acp_window_options = ACP_WINDOW_OPTIONS,
  custom_background_groups = custom_background_groups,
  set_suppress_transcript_window_refresh = function(value)
    suppress_transcript_window_refresh = value == true
  end,
  follow_scroll_off = FOLLOW_SCROLL_OFF,
  default_scroll_off = DEFAULT_SCROLL_OFF,
  acp_transcript_filetype = ACP_TRANSCRIPT_FILETYPE,
  cleanup_markdown_rendering = cleanup_markdown_rendering,
  is_metadata_popup_buffer = is_metadata_popup_buffer,
  line_has_heading = line_has_heading,
  jump_window_to_row = jump_window_to_row,
  transcript_line_count = function(bufnr)
    return transcript_line_count(bufnr)
  end,
  code_block_target_row = code_block_target_row,
  transcript_source_lines = function(...)
    return transcript_source_lines(...)
  end,
  scroll_buffer_to_end = function(...)
    return scroll_buffer_to_end(...)
  end,
  show_action_menu = show_action_menu,
  show_metadata_popup = show_metadata_popup,
  diff_view = function()
    return diff_view
  end,
  notify_transcript_read = function(pane_id)
    local handler = transcript_read_handlers[tostring(pane_id or "")]
    if type(handler) == "function" then
      pcall(handler)
    end
  end,
})
resolve_anchor_window = view_windowing.resolve_anchor_window
local to_bufnr = view_windowing.to_bufnr
local buffer_var = view_windowing.buffer_var
pane_id_for_bufnr = view_windowing.pane_id_for_bufnr
agent_name_for_bufnr = view_windowing.agent_name_for_bufnr
pane_opts_for_bufnr = view_windowing.pane_opts_for_bufnr
local transcript_table_layout = view_windowing.transcript_table_layout
fancy_mode_enabled = view_windowing.fancy_mode_enabled
local should_release_buffer_on_hide = view_windowing.should_release_buffer_on_hide
local resolve_release_buffer_on_hide = view_windowing.resolve_release_buffer_on_hide
local is_acp_buffer = view_windowing.is_acp_buffer
local clear_transcript_window = view_windowing.clear_transcript_window
local capture_window_options = view_windowing.capture_window_options
local redirect_buffer_from_transcript_window = view_windowing.redirect_buffer_from_transcript_window
layout_entry = view_windowing.layout_entry
local footer_padding_count = view_windowing.footer_padding_count
local should_follow_output = view_windowing.should_follow_output
local set_follow_output = view_windowing.set_follow_output
local pause_follow_output = view_windowing.pause_follow_output
set_window_size = view_windowing.set_window_size
local apply_transcript_window_opts = view_windowing.apply_transcript_window_opts
local refresh_transcript_window = view_windowing.refresh_transcript_window
local close_buffer_windows = view_windowing.close_buffer_windows
local save_window_views = view_windowing.save_window_views
local restore_window_views = view_windowing.restore_window_views
local release_transcript_buffer = view_windowing.release_transcript_buffer
local create_transcript_buffer = view_windowing.create_transcript_buffer
local adopt_transcript_buffer = view_windowing.adopt_transcript_buffer
first_visible_window = view_windowing.first_visible_window
buffer_is_visible = view_windowing.buffer_is_visible
transcript_max_lines = view_windowing.transcript_max_lines
request_buffer_redraw_impl = require("lazyagent.acp.view_buffer.redraw").new({
  layout_state = layout_state,
  buffer_is_visible = function(bufnr)
    return buffer_is_visible(bufnr)
  end,
})

local view_compaction = require("lazyagent.acp.view_buffer.compaction").new({
  pane_opts_for_bufnr = pane_opts_for_bufnr,
  collect_transcript_sections = collect_transcript_sections,
  runtime_conversation_timeline = runtime_conversation_timeline,
  layout_entry = layout_entry,
  trailing_markdown_table_context = trailing_markdown_table_context,
  trailing_section_has_open_markdown_fence = trailing_section_has_open_markdown_fence,
  balance_unclosed_markdown_fences = balance_unclosed_markdown_fences,
  transform_markdown_tables = transform_markdown_tables,
  transcript_table_layout = transcript_table_layout,
  fancy_mode_enabled = function(bufnr)
    return fancy_mode_enabled(bufnr)
  end,
  transcript_max_lines = function(bufnr)
    return transcript_max_lines(bufnr)
  end,
  transcript_truncated_marker = TRANSCRIPT_TRUNCATED_MARKER,
})
local transcript_compaction_config = view_compaction.transcript_compaction_config
pinned_section_rows = view_compaction.pinned_section_rows
local compact_transcript_lines = view_compaction.compact_transcript_lines
read_transcript_lines = view_compaction.read_transcript_lines

local function transcript_file_signature(path)
  if not path or path == "" then
    return ""
  end

  local stat = vim.loop.fs_stat(path)
  if not stat then
    return ""
  end

  local mtime = stat.mtime or {}
  return table.concat({
    tostring(stat.size or 0),
    tostring(mtime.sec or 0),
    tostring(mtime.nsec or 0),
  }, ":")
end

local function build_pinned_row_cache(lines, section_items)
  lines = type(lines) == "table" and lines or {}
  section_items = type(section_items) == "table" and section_items or {}
  local sections = collect_transcript_sections(lines)
  if #sections == 0 or #section_items ~= #sections then
    return nil
  end

  local pinned_rows = {}
  for idx, section in ipairs(sections) do
    if type(section_items[idx]) == "table" and section_items[idx].pinned == true then
      pinned_rows[section.start_row] = true
    end
  end
  return pinned_rows
end

set_buffer_lines = function(bufnr, lines, section_items, display_meta)
  local entry = layout_entry(bufnr)
  invalidate_transcript_section_cache(bufnr)
  entry.footer_padding_count = 0
  entry.footer_signature = nil
  entry.transcript_source_lines = nil
  entry.metadata_source_lines = vim.deepcopy(lines or {})
  entry.transcript_section_items = section_items or {}
  entry.transcript_display_meta = display_meta or {}
  entry.transcript_display_meta.pinned_rows = build_pinned_row_cache(lines, entry.transcript_section_items)
  replace_buffer_lines(bufnr, 0, -1, lines)
end

replace_buffer_lines = function(bufnr, start_idx, end_idx, lines)
  local original_modifiable = vim.bo[bufnr].modifiable
  vim.bo[bufnr].modifiable = true
  pcall(vim.api.nvim_buf_set_lines, bufnr, start_idx, end_idx, false, lines)
  vim.bo[bufnr].modifiable = original_modifiable
end

local view_updates = require("lazyagent.acp.view_buffer.updates").new({
  api = M,
  close_timer = close_timer,
  layout_entry = function(bufnr)
    return layout_entry(bufnr)
  end,
  footer_padding_count = footer_padding_count,
  replace_buffer_lines = function(...)
    return replace_buffer_lines(...)
  end,
  buffer_var = buffer_var,
  first_visible_window = function(bufnr)
    return first_visible_window(bufnr)
  end,
  pane_opts_for_bufnr = pane_opts_for_bufnr,
  apply_transcript_window_opts = apply_transcript_window_opts,
  apply_transcript_buffer_opts = view_windowing.apply_transcript_buffer_opts,
  redirect_buffer_from_transcript_window = redirect_buffer_from_transcript_window,
  is_acp_buffer = is_acp_buffer,
  is_metadata_popup_buffer = is_metadata_popup_buffer,
  pause_follow_output = pause_follow_output,
  refresh_transcript_window = refresh_transcript_window,
  refresh_buffer_layout = function(...)
    return refresh_buffer_layout(...)
  end,
  clear_transcript_window = clear_transcript_window,
  cleanup_markdown_rendering = cleanup_markdown_rendering,
  pane_buffers = pane_buffers,
  layout_state = layout_state,
  dedicated_transcript_windows = dedicated_transcript_windows,
  redirecting_transcript_windows = redirecting_transcript_windows,
  reset_appearance_cache = function()
    highlights_defined = false
    for key in pairs(custom_background_groups) do
      custom_background_groups[key] = nil
    end
  end,
  invalidate_transcript_section_cache = function(bufnr)
    return invalidate_transcript_section_cache(bufnr)
  end,
  suppress_transcript_window_refresh = function()
    return suppress_transcript_window_refresh
  end,
  follow_scroll_off = FOLLOW_SCROLL_OFF,
  save_window_views = save_window_views,
  should_follow_output = should_follow_output,
  transcript_file_signature = transcript_file_signature,
  transcript_compaction_config = transcript_compaction_config,
  read_transcript_lines = function(...)
    return read_transcript_lines(...)
  end,
  transcript_max_lines = function(bufnr)
    return transcript_max_lines(bufnr)
  end,
  compact_transcript_lines = compact_transcript_lines,
  set_buffer_lines = function(...)
    return set_buffer_lines(...)
  end,
  restore_window_views = restore_window_views,
  buffer_is_visible = function(bufnr)
    return buffer_is_visible(bufnr)
  end,
  to_bufnr = to_bufnr,
  session_for_agent = session_for_agent,
  agent_name_for_bufnr = function(bufnr)
    return agent_name_for_bufnr(bufnr)
  end,
  append_crosses_unclosed_markdown_fence = append_crosses_unclosed_markdown_fence,
  section_heading_for_line = section_heading_for_line,
  split_markdown_table_cells = split_markdown_table_cells,
  is_markdown_table_separator = is_markdown_table_separator,
  transcript_table_layout = transcript_table_layout,
  trailing_markdown_table_context = trailing_markdown_table_context,
  normalize_transcript_display = normalize_transcript_display,
  decorate_transcript_range = decorate_transcript_range,
  diff_view = function()
    return diff_view
  end,
  queue_markdown_rendering = queue_markdown_rendering,
  request_buffer_redraw = request_buffer_redraw,
  append_batch_ms = APPEND_BATCH_MS,
  acp_transcript_filetype = ACP_TRANSCRIPT_FILETYPE,
  trailing_section_has_open_markdown_fence = trailing_section_has_open_markdown_fence,
  is_markdown_fence = is_markdown_fence,
})
local set_footer_padding = view_updates.set_footer_padding
local ensure_layout_autocmds = view_updates.ensure_layout_autocmds
scroll_buffer_to_end = view_updates.scroll_buffer_to_end
transcript_line_count = view_updates.transcript_line_count
refresh_buffer_from_path = view_updates.refresh_buffer_from_path
local refresh_buffer_from_file = view_updates.refresh_buffer_from_file
local resume_deferred_updates_for_buffer = view_updates.resume_deferred_updates_for_buffer
local queue_append = view_updates.queue_append

diff_view = view_diff.new({
  diff_utils = require("lazyagent.acp.diff"),
  diff_ns = diff_ns,
  session_for_agent = session_for_agent,
  transcript_line_count = function(bufnr)
    return transcript_line_count(bufnr)
  end,
  transcript_lines = function(bufnr, start_idx, end_idx)
    return transcript_source_lines(bufnr, start_idx, end_idx)
  end,
  agent_name_for_bufnr = agent_name_for_bufnr,
})

footer_view = view_footer.new({
  agent_logic = agent_logic,
  state = state,
  footer_ns = footer_ns,
  session_for_agent = session_for_agent,
  agent_name_for_bufnr = agent_name_for_bufnr,
  transcript_line_count = function(bufnr)
    return transcript_line_count(bufnr)
  end,
  overlay_target_width = overlay_target_width,
  layout_entry = layout_entry,
  footer_padding_count = footer_padding_count,
  set_footer_padding = set_footer_padding,
  buffer_is_visible = function(bufnr)
    return buffer_is_visible(bufnr)
  end,
  is_acp_buffer = is_acp_buffer,
  should_follow_output = should_follow_output,
})

function M.statusline()
  return footer_view.statusline()
end

function M.refresh_footer(bufnr, opts)
  return footer_view.refresh_footer(bufnr, opts)
end

refresh_buffer_layout = function(bufnr, opts)
  opts = opts or {}
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  if buffer_var(bufnr, "lazyagent_acp_pane_id") == nil then
    return false
  end

  local entry = layout_entry(bufnr)
  local header_width = header_target_width(bufnr) or 0
  local footer_width = overlay_target_width(bufnr)
  local transcript_count = transcript_line_count(bufnr)
  local decorate_needed = opts.force_decorate == true
    or entry.transcript_count ~= transcript_count
    or entry.header_width ~= header_width
  local footer_needed = opts.force_footer == true
    or opts.check_footer == true
    or decorate_needed
    or entry.footer_width ~= footer_width
  local render_needed = opts.force_render == true or decorate_needed

  entry.header_width = header_width
  entry.footer_width = footer_width
  entry.transcript_count = transcript_count

  if decorate_needed then
    decorate_buffer(bufnr)
  end
  if footer_needed then
    M.refresh_footer(bufnr, { force = opts.force_footer == true or decorate_needed })
  end
  if should_follow_output(bufnr) then
    scroll_buffer_to_end(bufnr)
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        M._notify_transcript_read(bufnr)
      end
    end)
  end
  if render_needed then
    entry.markdown_render_pending = false
    entry.markdown_render_token = nil
    refresh_markdown_rendering(bufnr)
  end
  return decorate_needed or footer_needed or render_needed
end

require("lazyagent.acp.view_buffer.api").attach(M, {
  footer_view = footer_view,
  ensure_layout_autocmds = ensure_layout_autocmds,
  to_bufnr = to_bufnr,
  save_window_views = save_window_views,
  pane_config = pane_config,
  transcript_read_handlers = transcript_read_handlers,
  first_visible_window = function(bufnr)
    return first_visible_window(bufnr)
  end,
  restore_window_views = restore_window_views,
  resolve_anchor_window = resolve_anchor_window,
  capture_window_options = capture_window_options,
  set_window_size = function(...)
    return set_window_size(...)
  end,
  create_transcript_buffer = create_transcript_buffer,
  adopt_transcript_buffer = adopt_transcript_buffer,
  apply_transcript_window_opts = apply_transcript_window_opts,
  refresh_buffer_from_path = function(...)
    return refresh_buffer_from_path(...)
  end,
  refresh_buffer_from_file = refresh_buffer_from_file,
  resume_deferred_updates_for_buffer = resume_deferred_updates_for_buffer,
  refresh_buffer_layout = function(...)
    return refresh_buffer_layout(...)
  end,
  cleanup_markdown_rendering = cleanup_markdown_rendering,
  close_buffer_windows = close_buffer_windows,
  should_release_buffer_on_hide = should_release_buffer_on_hide,
  release_transcript_buffer = release_transcript_buffer,
  resolve_release_buffer_on_hide = resolve_release_buffer_on_hide,
  buffer_var = buffer_var,
  set_follow_output = set_follow_output,
  pause_follow_output = pause_follow_output,
  pane_buffers = pane_buffers,
  layout_state = layout_state,
  dedicated_transcript_windows = dedicated_transcript_windows,
  redirecting_transcript_windows = redirecting_transcript_windows,
  should_follow_output = should_follow_output,
  scroll_buffer_to_end = function(...)
    return scroll_buffer_to_end(...)
  end,
  close_timer = close_timer,
  queue_append = queue_append,
  allocate_pane_id = function(prefix)
    next_pane_seq = next_pane_seq + 1
    return string.format("%s-%d", prefix, next_pane_seq)
  end,
})

local function clamp_mobile_tail(lines, tail)
  lines = type(lines) == "table" and lines or {}
  tail = math.max(1, math.floor(tonumber(tail) or 420))
  local total = #lines
  if total <= tail then
    return lines, 0, total, false
  end
  return vim.list_slice(lines, total - tail + 1, total), total - tail, total, true
end

function M.mobile_transcript_snapshot(agent_name, opts)
  opts = opts or {}
  agent_name = tostring(agent_name or "")
  local session = state.sessions and state.sessions[agent_name] or nil
  if type(session) ~= "table" then
    return nil, "ACP session not found: " .. agent_name
  end

  local pane_id = session.pane_id and tostring(session.pane_id) or nil
  local bufnr = pane_id and to_bufnr(pane_id) or nil
  local tail = math.min(math.max(1, math.floor(tonumber(opts.tail) or 420)), 1600)

  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(M.sync_mobile_transcript, pane_id)
    local total = transcript_line_count(bufnr)
    local start_idx = math.max(0, total - tail)
    local lines = vim.api.nvim_buf_get_lines(bufnr, start_idx, total, false)
    return {
      agent = agent_name,
      pane_id = pane_id,
      bufnr = bufnr,
      source = "buffer",
      lines = lines,
      start_line = start_idx + 1,
      line_count = total,
      truncated = start_idx > 0,
      changedtick = changedtick(bufnr),
      follow = should_follow_output(bufnr),
    }
  end

  local path = session.acp_transcript_path or session.transcript_path
  local lines = read_transcript_lines(path, tail)
  local sliced, start_idx, total, truncated = clamp_mobile_tail(lines, tail)
  return {
    agent = agent_name,
    pane_id = pane_id,
    source = "file",
    lines = sliced,
    start_line = start_idx + 1,
    line_count = total,
    truncated = truncated,
    changedtick = 0,
    follow = true,
  }
end

function M.mirror_snapshot(pane_id)
  pane_id = pane_id and tostring(pane_id) or nil
  local bufnr = pane_id and to_bufnr(pane_id) or nil
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local total = transcript_line_count(bufnr)
  return {
    pane_id = pane_id,
    bufnr = bufnr,
    source = "buffer",
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, total, false),
    line_count = total,
    changedtick = changedtick(bufnr),
  }
end

function M.transcript_is_read(pane_id)
  local bufnr = to_bufnr(pane_id)
  return bufnr ~= nil and M._transcript_is_read(bufnr) or false
end

return M
