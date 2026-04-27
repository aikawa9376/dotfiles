local M = {}

local agent_logic = require("lazyagent.logic.agent")
local state = require("lazyagent.logic.state")
local view_diff = require("lazyagent.acp.view_diff")
local view_footer = require("lazyagent.acp.view_footer")
local pane_config = {}
local pane_buffers = {}
local next_pane_seq = 0
local transcript_ns = vim.api.nvim_create_namespace("lazyagent_acp_transcript")
local footer_ns = vim.api.nvim_create_namespace("lazyagent_acp_footer")
local diff_ns = vim.api.nvim_create_namespace("lazyagent_acp_diff")
local highlights_defined = false
local layout_autocmds_initialized = false
local TRANSCRIPT_TRUNCATED_MARKER = "... earlier transcript omitted from buffer ..."
local FOLLOW_SCROLL_OFF = 0
local DEFAULT_SCROLL_OFF = 2
local ACP_TRANSCRIPT_FILETYPE = "lazyagent_acp"
local APPEND_BATCH_MS = 60
local DECORATE_PREFETCH_MARGIN = 80
local DECORATE_SYNC_LINE_LIMIT = 600
local DECORATE_CHUNK_SIZE = 400
local first_visible_window
local replace_buffer_lines
local set_buffer_lines
local scroll_buffer_to_end
local transcript_line_count
local refresh_buffer_layout
local refresh_buffer_from_path
local layout_entry
local buffer_is_visible
local set_window_size
local diff_view
local footer_view
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
    LazyAgentACPBorder = { default = true, link = "FloatBorder" },
    LazyAgentACPFooterActive = { default = true, link = "DiagnosticInfo" },
    LazyAgentACPFooterWaiting = { default = true, link = "DiagnosticWarn" },
    LazyAgentACPFooterError = { default = true, link = "DiagnosticError" },
    LazyAgentACPFooterMuted = { default = true, link = "Comment" },
    LazyAgentACPFooterMeta = { default = true, link = "SpecialComment" },
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

  pcall(vim.treesitter.start, bufnr, "markdown")

  local ok_manager, manager = pcall(require, "render-markdown.core.manager")
  if ok_manager and type(manager.attach) == "function" then
    pcall(manager.attach, bufnr)
  end

  local wins = vim.fn.win_findbuf(bufnr)
  if #wins == 0 then
    return
  end

  local ok_render, render = pcall(require, "render-markdown")
  if ok_render and type(render.render) == "function" then
    pcall(render.render, {
      buf = bufnr,
      win = wins,
      event = "LazyAgentACPUpdate",
    })
  end
end

local function session_for_agent(agent_name)
  return agent_name and state.sessions and state.sessions[agent_name] or nil
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

local function cancel_deferred_decoration(bufnr)
  local entry = layout_entry(bufnr)
  entry.decoration_generation = (entry.decoration_generation or 0) + 1
  return entry.decoration_generation
end

local function visible_transcript_range(bufnr)
  local transcript_stop = transcript_line_count(bufnr)
  if transcript_stop <= 0 then
    return 0, 0
  end

  local win = first_visible_window(bufnr)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return 0, math.min(transcript_stop, DECORATE_CHUNK_SIZE)
  end

  local ok, bounds = pcall(vim.api.nvim_win_call, win, function()
    return { vim.fn.line("w0"), vim.fn.line("w$") }
  end)
  if not ok or type(bounds) ~= "table" then
    return 0, math.min(transcript_stop, DECORATE_CHUNK_SIZE)
  end

  local top = math.max(1, tonumber(bounds[1]) or 1)
  local bottom = math.max(top, tonumber(bounds[2]) or top)
  local range_start = math.max(0, top - 1 - DECORATE_PREFETCH_MARGIN)
  local range_stop = math.min(transcript_stop, bottom + DECORATE_PREFETCH_MARGIN)
  return range_start, math.max(range_start, range_stop)
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
    local row = range_start + idx - 1
    if line:match("^─ ") or line:match("^╭─ ") then
      local header_hl = section_style_for_line(line)
      -- Prefer using vim.highlight.range for a full-line highlight region. Fall back to
      -- extmark or nvim_buf_add_highlight if not available.
      local ok = pcall(function()
        local start_pos = { row, 0 }
        local end_pos = { row, #line }
        vim.highlight.range(bufnr, transcript_ns, header_hl, start_pos, end_pos)
      end)
      if not ok then
        local ok2 = pcall(function()
          vim.api.nvim_buf_set_extmark(bufnr, transcript_ns, row, 0, { hl_group = header_hl, hl_eol = true })
        end)
        if not ok2 then
          pcall(function() vim.api.nvim_buf_add_highlight(bufnr, transcript_ns, header_hl, row, 0, -1) end)
        end
      end
    end
  end
end

local function queue_deferred_transcript_decoration(bufnr, ranges, generation)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local entry = layout_entry(bufnr)
  local function step(range_idx, cursor)
    if not vim.api.nvim_buf_is_valid(bufnr) or entry.decoration_generation ~= generation then
      return
    end
    if not buffer_is_visible(bufnr) then
      entry.pending_full_refresh = true
      return
    end

    local range = ranges[range_idx]
    if not range then
      return
    end

    local start_idx = cursor or range[1]
    local next_stop = math.min(range[2], start_idx + DECORATE_CHUNK_SIZE)
    decorate_transcript_range(bufnr, start_idx, next_stop)
    if next_stop < range[2] then
      vim.schedule(function()
        step(range_idx, next_stop)
      end)
      return
    end

    vim.schedule(function()
      step(range_idx + 1)
    end)
  end

  vim.schedule(function()
    step(1)
  end)
end

local function decorate_buffer(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local transcript_stop = transcript_line_count(bufnr)
  local generation = cancel_deferred_decoration(bufnr)
  if transcript_stop <= 0 then
    return
  end

  if transcript_stop <= DECORATE_SYNC_LINE_LIMIT or not buffer_is_visible(bufnr) then
    decorate_transcript_range(bufnr, 0, transcript_stop)
    diff_view.decorate_diff_blocks(bufnr)
    return
  end

  local visible_start, visible_stop = visible_transcript_range(bufnr)
  decorate_transcript_range(bufnr, visible_start, visible_stop)

  local ranges = {}
  if visible_start > 0 then
    ranges[#ranges + 1] = { 0, visible_start }
  end
  if visible_stop < transcript_stop then
    ranges[#ranges + 1] = { visible_stop, transcript_stop }
  end
  if #ranges > 0 then
    queue_deferred_transcript_decoration(bufnr, ranges, generation)
  end
  diff_view.decorate_diff_blocks(bufnr)
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
  local key = tostring(pane_id or "")
  local tracked = pane_buffers[key]
  if tracked and vim.api.nvim_buf_is_valid(tracked) then
    return tracked
  end
  pane_buffers[key] = nil

  local n = tonumber(pane_id)
  if n and vim.api.nvim_buf_is_valid(n) then
    pane_buffers[key] = n
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

local function is_acp_buffer(bufnr)
  return buffer_var(bufnr, "lazyagent_acp_pane_id") ~= nil
end

local function tracked_transcript_window(win)
  local key = tostring(win or "")
  local entry = dedicated_transcript_windows[key]
  if entry == nil then
    return nil
  end
  if not win or not vim.api.nvim_win_is_valid(win) then
    dedicated_transcript_windows[key] = nil
    redirecting_transcript_windows[key] = nil
    return nil
  end
  return entry
end

local function track_transcript_window(win, pane_id, bufnr)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  dedicated_transcript_windows[tostring(win)] = {
    pane_id = tostring(pane_id),
    bufnr = bufnr,
  }
end

local function clear_transcript_window(win)
  local key = tostring(win or "")
  dedicated_transcript_windows[key] = nil
  redirecting_transcript_windows[key] = nil
end

local function reset_window_from_defaults(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  pcall(vim.api.nvim_win_call, win, function()
    for _, option in ipairs(ACP_WINDOW_OPTIONS) do
      pcall(vim.cmd, "setlocal " .. option .. "<")
    end
  end)
end

local function capture_window_options(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return nil
  end
  local snapshot = {}
  for _, option in ipairs(ACP_WINDOW_OPTIONS) do
    local ok, value = pcall(vim.api.nvim_get_option_value, option, { win = win })
    if ok then
      snapshot[option] = value
    end
  end
  return snapshot
end

local function apply_window_options(win, snapshot)
  if not win or not vim.api.nvim_win_is_valid(win) or type(snapshot) ~= "table" then
    return false
  end
  for _, option in ipairs(ACP_WINDOW_OPTIONS) do
    if snapshot[option] ~= nil then
      pcall(vim.api.nvim_set_option_value, option, snapshot[option], { win = win })
    end
  end
  return true
end

local function normalize_redirect_target_window(win, pane_opts)
  if apply_window_options(win, pane_opts and pane_opts.source_window_options) then
    return
  end
  reset_window_from_defaults(win)
end

local function restore_transcript_window_size(win, pane_opts)
  if not pane_opts or not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  set_window_size(win, pane_opts.pane_size, pane_opts.is_vertical == true)
end

local function usable_redirect_target(win, source_win)
  if not is_normal_window(win) or win == source_win or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  if tracked_transcript_window(win) ~= nil then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(win)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  local buftype = vim.bo[buf].buftype
  return buftype == "" or buftype == "acwrite"
end

local function find_redirect_target_window(source_win, pane_opts)
  local anchor = resolve_anchor_window(pane_opts and pane_opts.source_winid)
  if usable_redirect_target(anchor, source_win) then
    return anchor, false
  end

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if usable_redirect_target(win, source_win) then
      return win, false
    end
  end

  local created = nil
  pcall(function()
    vim.api.nvim_set_current_win(source_win)
    if pane_opts and pane_opts.is_vertical == true then
      vim.cmd("leftabove vsplit")
    else
      vim.cmd("leftabove split")
    end
    created = vim.api.nvim_get_current_win()
    normalize_redirect_target_window(created, pane_opts)
    restore_transcript_window_size(source_win, pane_opts)
  end)
  return created, created ~= nil
end

local function redirect_buffer_from_transcript_window(win, bufnr)
  local tracked = tracked_transcript_window(win)
  if tracked == nil or tracked.bufnr == bufnr then
    return false
  end
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or is_acp_buffer(bufnr) then
    return false
  end

  local key = tostring(win)
  if redirecting_transcript_windows[key] then
    return false
  end

  local restore_buf = tracked.bufnr
  if not restore_buf or not vim.api.nvim_buf_is_valid(restore_buf) then
    restore_buf = to_bufnr(tracked.pane_id)
    if restore_buf and vim.api.nvim_buf_is_valid(restore_buf) then
      tracked.bufnr = restore_buf
    end
  end
  if not restore_buf or not vim.api.nvim_buf_is_valid(restore_buf) then
    clear_transcript_window(win)
    return false
  end

  redirecting_transcript_windows[key] = true
  local pane_opts = pane_config[tracked.pane_id] or pane_opts_for_bufnr(restore_buf)
  local target_win = select(1, find_redirect_target_window(win, pane_opts))
  if not target_win or not vim.api.nvim_win_is_valid(target_win) then
    redirecting_transcript_windows[key] = nil
    return false
  end

  pcall(vim.api.nvim_win_set_buf, target_win, bufnr)
  pcall(vim.api.nvim_win_set_buf, win, restore_buf)
  track_transcript_window(win, tracked.pane_id, restore_buf)
  if pane_config[tracked.pane_id] ~= nil then
    pane_config[tracked.pane_id].source_winid = target_win
    pane_config[tracked.pane_id].source_window_options = capture_window_options(target_win)
  end
  pcall(vim.api.nvim_set_current_win, target_win)
  redirecting_transcript_windows[key] = nil
  return true
end

layout_entry = function(bufnr)
  local key = tostring(bufnr)
  local entry = layout_state[key]
  if not entry then
    entry = {}
    layout_state[key] = entry
  end
  return entry
end

local function footer_padding_count(bufnr)
  return math.max(0, tonumber(layout_entry(bufnr).footer_padding_count) or 0)
end

local function background_group_name(base_group, bg)
  return "LazyAgentACP" .. tostring(base_group):gsub("[^%w]+", "") .. "Bg"
    .. tostring(bg):gsub("[^%w]+", "_")
end

local function window_background_group(base_group, bg)
  if not bg or bg == "" then
    return nil
  end

  local key = tostring(base_group) .. "\0" .. tostring(bg)
  local group = custom_background_groups[key] or background_group_name(base_group, bg)
  custom_background_groups[key] = group

  local spec = {}
  local ok, base = pcall(vim.api.nvim_get_hl, 0, { name = base_group, link = false })
  if ok and type(base) == "table" then
    spec = vim.deepcopy(base)
  end
  spec.bg = bg
  spec.default = nil
  spec.ctermbg = nil
  pcall(vim.api.nvim_set_hl, 0, group, spec)
  return group
end

local function apply_transcript_background(win, appearance)
  appearance = appearance or {}
  local active_bg = appearance.buffer_background
  local inactive_bg = appearance.buffer_inactive_background or active_bg

  local mappings = {}
  local active_group = window_background_group("Normal", active_bg)
  local inactive_group = window_background_group("NormalNC", inactive_bg)
  if active_group then
    mappings.Normal = active_group
    mappings.EndOfBuffer = active_group
  else
    mappings.EndOfBuffer = "None"
  end
  if inactive_group then
    mappings.NormalNC = inactive_group
  end
  if next(mappings) ~= nil then
    local current = vim.wo[win].winhighlight
    local merged = {}
    local order = {}
    for _, part in ipairs(vim.split(current or "", ",", { trimempty = true })) do
      local key, value = part:match("^([^:]+):(.+)$")
      if key and value then
        if merged[key] == nil then
          order[#order + 1] = key
        end
        merged[key] = value
      end
    end
    for key, value in pairs(mappings) do
      if merged[key] == nil then
        order[#order + 1] = key
      end
      merged[key] = value
    end
    local rendered = {}
    for _, key in ipairs(order) do
      rendered[#rendered + 1] = key .. ":" .. merged[key]
    end
    vim.wo[win].winhighlight = table.concat(rendered, ",")
  end
end

local function hide_end_of_buffer_fill(win)
  local current = vim.api.nvim_get_option_value("fillchars", { win = win })
  local parts = vim.split(current or "", ",", { trimempty = true })
  local filtered = {}
  for _, part in ipairs(parts) do
    if not vim.startswith(part, "eob:") then
      filtered[#filtered + 1] = part
    end
  end
  filtered[#filtered + 1] = "eob: "
  vim.api.nvim_set_option_value("fillchars", table.concat(filtered, ","), { win = win })
end

local function should_follow_output(bufnr)
  return pane_opts_for_bufnr(bufnr).follow_output ~= false
end

local function set_follow_output(bufnr, enabled)
  local pane_id = tostring(pane_id_for_bufnr(bufnr))
  pane_config[pane_id] = vim.tbl_extend("force", pane_config[pane_id] or {}, {
    follow_output = enabled ~= false,
  })
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(win) then
      vim.wo[win].scrolloff = (enabled ~= false) and FOLLOW_SCROLL_OFF or DEFAULT_SCROLL_OFF
    end
  end
end

set_window_size = function(win, size, is_vertical)
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

local function apply_transcript_window_opts(win, is_vertical, appearance)
  pcall(function()
    suppress_transcript_window_refresh = true
    local bufnr = vim.api.nvim_win_get_buf(win)
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].cursorline = false
    vim.wo[win].wrap = true
    vim.wo[win].linebreak = true
    vim.wo[win].breakindent = true
    vim.wo[win].signcolumn = "no"
    vim.wo[win].statuscolumn = ""
    vim.wo[win].foldcolumn = "0"
    vim.wo[win].foldenable = false
    vim.wo[win].foldmethod = "manual"
    vim.wo[win].foldexpr = "0"
    vim.wo[win].winfixwidth = is_vertical == true
    vim.wo[win].winfixheight = is_vertical ~= true
    vim.wo[win].scrolloff = should_follow_output(bufnr) and FOLLOW_SCROLL_OFF or DEFAULT_SCROLL_OFF
    vim.wo[win].statusline = ""
    vim.wo[win].eventignorewin = ""
    hide_end_of_buffer_fill(win)
  end)
  pcall(apply_transcript_background, win, appearance)
  local bufnr = vim.api.nvim_win_get_buf(win)
  track_transcript_window(win, pane_id_for_bufnr(bufnr), bufnr)
  suppress_transcript_window_refresh = false
end

local function refresh_transcript_window(bufnr, win)
  if not bufnr or buffer_var(bufnr, "lazyagent_acp_pane_id") == nil then
    return
  end
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  if vim.api.nvim_win_get_buf(win) ~= bufnr then
    return
  end

  local opts = pane_opts_for_bufnr(bufnr)
  apply_transcript_window_opts(win, opts.is_vertical == true, opts)
end

local function apply_transcript_buffer_opts(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  pcall(function()
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].undofile = false
    vim.bo[bufnr].buflisted = false
    vim.b[bufnr].lazyagent_acp_transcript = true
    vim.b[bufnr].illuminate_disable = true
    vim.b[bufnr].matchup_matchparen_enabled = 0
  end)
  pcall(vim.api.nvim_set_option_value, "spell", false, { buf = bufnr })

  -- Buffer-local mappings: jump between User sections with ]] and [[
  local function jump_to_user(forward)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
    local win = vim.api.nvim_get_current_win()
    local cur = vim.api.nvim_win_get_cursor(win)
    local cur_row = cur[1]
    local stop = transcript_line_count(bufnr)
    if forward then
      for r = cur_row + 1, stop do
        local line = vim.api.nvim_buf_get_lines(bufnr, r - 1, r, false)[1] or ""
        if line_has_heading(line, "User") then
          pcall(function()
            vim.api.nvim_win_set_cursor(win, { r, 0 })
            pcall(vim.cmd, "normal! zz")
          end)
          return
        end
      end
      vim.notify("No later User section", vim.log.levels.INFO)
    else
      for r = math.max(1, cur_row - 1), 1, -1 do
        local line = vim.api.nvim_buf_get_lines(bufnr, r - 1, r, false)[1] or ""
        if line_has_heading(line, "User") then
          pcall(function()
            vim.api.nvim_win_set_cursor(win, { r, 0 })
            pcall(vim.cmd, "normal! zz")
          end)
          return
        end
      end
      vim.notify("No earlier User section", vim.log.levels.INFO)
    end
  end

  pcall(function()
    vim.keymap.set("n", "]]", function() jump_to_user(true) end, { buffer = bufnr, noremap = true, silent = true, desc = "LazyAgentACP: next User" })
    vim.keymap.set("n", "[[", function() jump_to_user(false) end, { buffer = bufnr, noremap = true, silent = true, desc = "LazyAgentACP: prev User" })
    vim.keymap.set("n", "<C-u>", function()
      M.scroll_up(pane_id_for_bufnr(bufnr))
    end, { buffer = bufnr, noremap = true, silent = true, desc = "LazyAgentACP: half page up" })
    vim.keymap.set("n", "<C-d>", function()
      M.scroll_down(pane_id_for_bufnr(bufnr))
    end, { buffer = bufnr, noremap = true, silent = true, desc = "LazyAgentACP: half page down" })
    vim.keymap.set("n", "<CR>", function()
      if diff_view and diff_view.open_diff_block_under_cursor(bufnr) then
        return
      end
      vim.cmd("normal! <CR>")
    end, { buffer = bufnr, noremap = true, silent = true, desc = "LazyAgentACP: open diff block" })
  end)

end

local function close_buffer_windows(bufnr)
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
end

local function create_transcript_buffer(pane_id, agent_name, transcript_path)
  local bufnr = vim.api.nvim_create_buf(false, true)
  local safe_agent_name = tostring(agent_name or "agent"):gsub("[^%w-_]+", "-")
  local pane_key = tostring(pane_id)

  pcall(function()
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "hide"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].buflisted = false
    vim.bo[bufnr].undofile = false
    vim.b[bufnr].lazyagent_acp_transcript = true
    vim.bo[bufnr].filetype = ACP_TRANSCRIPT_FILETYPE
    vim.api.nvim_buf_set_name(bufnr, string.format("lazyagent://acp/%s-%s", safe_agent_name, pane_key))
    vim.b[bufnr].lazyagent_acp_pane_id = pane_key
    vim.b[bufnr].lazyagent_acp_agent = agent_name
    vim.b[bufnr].lazyagent_acp_transcript_path = transcript_path
  end)
  apply_transcript_buffer_opts(bufnr)

  pane_buffers[pane_key] = bufnr
  return bufnr
end

first_visible_window = function(bufnr)
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(win) then
      return win
    end
  end
  return nil
end

buffer_is_visible = function(bufnr)
  return first_visible_window(bufnr) ~= nil
end

local function transcript_max_lines(bufnr)
  local opts = pane_opts_for_bufnr(bufnr)
  local value = tonumber(opts and opts.transcript_max_lines)
  if value and value > 0 then
    return math.floor(value)
  end
  return nil
end

local function read_transcript_lines(path, max_lines)
  if not path or path == "" or vim.fn.filereadable(path) ~= 1 then
    return {}
  end

  max_lines = tonumber(max_lines)
  if max_lines and max_lines > 0 and vim.fn.executable("tail") == 1 then
    local data = vim.fn.systemlist({ "tail", "-n", tostring(max_lines + 1), path })
    if vim.v.shell_error == 0 and type(data) == "table" then
      if #data > max_lines then
        data = vim.list_slice(data, #data - max_lines + 1, #data)
        table.insert(data, 1, TRANSCRIPT_TRUNCATED_MARKER)
      end
      return data
    end
  end

  local ok, data = pcall(vim.fn.readfile, path)
  if not ok or not data then
    return {}
  end
  if max_lines and max_lines > 0 and #data > max_lines then
    data = vim.list_slice(data, #data - max_lines + 1, #data)
    table.insert(data, 1, TRANSCRIPT_TRUNCATED_MARKER)
  end
  return data
end

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

set_buffer_lines = function(bufnr, lines)
  local entry = layout_entry(bufnr)
  entry.footer_padding_count = 0
  entry.footer_signature = nil
  replace_buffer_lines(bufnr, 0, -1, lines)
end

replace_buffer_lines = function(bufnr, start_idx, end_idx, lines)
  local original_modifiable = vim.bo[bufnr].modifiable
  vim.bo[bufnr].modifiable = true
  pcall(vim.api.nvim_buf_set_lines, bufnr, start_idx, end_idx, false, lines)
  vim.bo[bufnr].modifiable = original_modifiable
end

local function set_footer_padding(bufnr, count)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local entry = layout_entry(bufnr)
  local current = footer_padding_count(bufnr)
  local target = math.max(0, tonumber(count) or 0)
  if current == target then
    return
  end

  local transcript_stop = transcript_line_count(bufnr)
  local padding = {}
  for _ = 1, target do
    padding[#padding + 1] = ""
  end
  replace_buffer_lines(bufnr, transcript_stop, -1, padding)
  entry.footer_padding_count = target
end

local function ensure_layout_autocmds()
  if layout_autocmds_initialized then
    return
  end
  layout_autocmds_initialized = true

  local group = vim.api.nvim_create_augroup("LazyAgentACPLayout", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = ACP_TRANSCRIPT_FILETYPE,
    callback = function(args)
      apply_transcript_buffer_opts(tonumber(args.buf))
    end,
  })

  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = group,
    callback = function()
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if buffer_var(bufnr, "lazyagent_acp_pane_id") ~= nil and first_visible_window(bufnr) then
          for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
            if vim.api.nvim_win_is_valid(win) then
              local opts = pane_opts_for_bufnr(bufnr)
              apply_transcript_window_opts(win, opts.is_vertical == true, opts)
            end
          end
          pcall(refresh_buffer_layout, bufnr)
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function(args)
      local bufnr = tonumber(args.buf)
      if not bufnr then
        return
      end
      if redirect_buffer_from_transcript_window(vim.api.nvim_get_current_win(), bufnr) then
        return
      end
      if not is_acp_buffer(bufnr) then
        return
      end
      apply_transcript_buffer_opts(bufnr)
      for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
        refresh_transcript_window(bufnr, win)
      end
      if layout_entry(bufnr).pending_full_refresh then
        pcall(refresh_buffer_from_path, bufnr, buffer_var(bufnr, "lazyagent_acp_transcript_path"))
      else
        pcall(refresh_buffer_layout, bufnr)
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(args)
      local bufnr = tonumber(args.buf)
      if not bufnr or is_acp_buffer(bufnr) then
        return
      end
      redirect_buffer_from_transcript_window(vim.api.nvim_get_current_win(), bufnr)
    end,
  })

  vim.api.nvim_create_autocmd("WinEnter", {
    group = group,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      local bufnr = vim.api.nvim_get_current_buf()
      if is_acp_buffer(bufnr) then
        refresh_transcript_window(bufnr, win)
        return
      end
      redirect_buffer_from_transcript_window(win, bufnr)
    end,
  })

  vim.api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = { "fillchars", "winhighlight", "foldenable", "foldmethod", "foldexpr", "foldcolumn" },
    callback = function()
      if suppress_transcript_window_refresh then
        return
      end
      local win = vim.api.nvim_get_current_win()
      local bufnr = vim.api.nvim_get_current_buf()
      if not bufnr or buffer_var(bufnr, "lazyagent_acp_pane_id") == nil then
        return
      end
      vim.schedule(function()
        refresh_transcript_window(bufnr, win)
      end)
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(args)
      local bufnr = tonumber(args.buf)
      if not bufnr then
        return
      end
      local pane_id = buffer_var(bufnr, "lazyagent_acp_pane_id")
      if pane_id ~= nil and pane_buffers[tostring(pane_id)] == bufnr then
        pane_buffers[tostring(pane_id)] = nil
      end
      layout_state[tostring(bufnr)] = nil
      for key, entry in pairs(dedicated_transcript_windows) do
        if entry.bufnr == bufnr or tostring(entry.pane_id or "") == tostring(pane_id or "") then
          dedicated_transcript_windows[key] = nil
          redirecting_transcript_windows[key] = nil
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(args)
      clear_transcript_window(tonumber(args.match))
    end,
  })

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      highlights_defined = false
      custom_background_groups = {}
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if buffer_var(bufnr, "lazyagent_acp_pane_id") ~= nil and first_visible_window(bufnr) then
          for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
            if vim.api.nvim_win_is_valid(win) then
              local opts = pane_opts_for_bufnr(bufnr)
              apply_transcript_window_opts(win, opts.is_vertical == true, opts)
            end
          end
          pcall(refresh_buffer_layout, bufnr, { force_decorate = true, force_footer = true })
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
      pcall(vim.api.nvim_win_call, win, function()
        vim.wo[win].scrolloff = FOLLOW_SCROLL_OFF
        vim.api.nvim_win_set_cursor(win, { row, col })
        vim.cmd("silent! normal! zb")
      end)
    end
  end
end

transcript_line_count = function(bufnr)
  local count = math.max(0, vim.api.nvim_buf_line_count(bufnr) - footer_padding_count(bufnr))
  if count == 1 then
    local first = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ""
    if first == "" then
      return 0
    end
  end
  return count
end

local function append_text_to_buffer(bufnr, text)
  if not text or text == "" or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local transcript_stop = transcript_line_count(bufnr)
  local replace_start = transcript_stop
  local current_last = ""
  if transcript_stop > 0 then
    replace_start = transcript_stop - 1
    current_last = vim.api.nvim_buf_get_lines(bufnr, replace_start, transcript_stop, false)[1] or ""
  end
  set_footer_padding(bufnr, 0)
  layout_entry(bufnr).footer_signature = nil
  local total_lines = vim.api.nvim_buf_line_count(bufnr)

  local chunks = vim.split(text, "\n", { plain = true })
  local replacement = { current_last .. table.remove(chunks, 1) }
  vim.list_extend(replacement, chunks)

  replace_buffer_lines(bufnr, replace_start, total_lines, replacement)
  return replace_start
end

refresh_buffer_from_path = function(bufnr, transcript_path, opts)
  opts = opts or {}
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  local entry = layout_entry(bufnr)
  local signature = transcript_file_signature(transcript_path)
  if not opts.force and entry.transcript_file_signature == signature then
    entry.pending_full_refresh = false
    refresh_buffer_layout(bufnr, opts.layout or {})
    return false
  end

  local lines = read_transcript_lines(transcript_path, transcript_max_lines(bufnr))

  set_buffer_lines(bufnr, lines)
  entry.pending_full_refresh = false
  entry.transcript_file_signature = signature
  refresh_buffer_layout(bufnr, { force_decorate = true, force_footer = true })
  return true
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

    if not buffer_is_visible(bufnr) then
      layout_entry(bufnr).pending_full_refresh = true
      return
    end

    refresh_buffer_from_path(bufnr, session.transcript_path)
  end)
end

local function queue_append(session, text)
  local bufnr = to_bufnr(session and session.pane_id)
  if not bufnr then
    return
  end

  session.view_state = session.view_state or {}
  session.view_state.pending_append = (session.view_state.pending_append or "") .. tostring(text or "")

  local function flush_pending_append()
    close_timer(session.view_state.append_timer)
    session.view_state.append_timer = nil
    if not vim.api.nvim_buf_is_valid(bufnr) then
      session.view_state.pending_append = ""
      return
    end
    local pending = session.view_state.pending_append or ""
    session.view_state.pending_append = ""
    if pending == "" then
      return
    end
    if not buffer_is_visible(bufnr) then
      layout_entry(bufnr).pending_full_refresh = true
      return
    end
    local changed_start = append_text_to_buffer(bufnr, pending)
    local max_lines = transcript_max_lines(bufnr)
    if max_lines and max_lines > 0 and transcript_line_count(bufnr) > (max_lines + 1) then
      refresh_buffer_from_path(bufnr, session.transcript_path)
    elseif changed_start ~= nil then
      decorate_transcript_range(bufnr, changed_start, transcript_line_count(bufnr))
      diff_view.decorate_diff_blocks(bufnr)
    end
    layout_entry(bufnr).transcript_file_signature = transcript_file_signature(session.transcript_path)
    M.refresh_footer(bufnr)
    if should_follow_output(bufnr) then
      scroll_buffer_to_end(bufnr)
    end
  end

  if session.view_state.append_timer then
    return
  end

  local uv = vim.uv or vim.loop
  if not uv or not uv.new_timer then
    vim.schedule(flush_pending_append)
    return
  end

  local timer = uv.new_timer()
  session.view_state.append_timer = timer
  timer:start(APPEND_BATCH_MS, 0, vim.schedule_wrap(flush_pending_append))
end

diff_view = view_diff.new({
  diff_utils = require("lazyagent.acp.diff"),
  diff_ns = diff_ns,
  session_for_agent = session_for_agent,
  transcript_line_count = function(bufnr)
    return transcript_line_count(bufnr)
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
    or decorate_needed
    or entry.footer_width ~= footer_width

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
  end
  refresh_markdown_rendering(bufnr)
  return decorate_needed or footer_needed
end

function M.refresh_all_footers()
  return footer_view.refresh_all_footers()
end

function M.refresh_agent_footers(agent_name, opts)
  return footer_view.refresh_agent_footers(agent_name, opts)
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

  next_pane_seq = next_pane_seq + 1
  local pane_id = string.format("buffer-acp-%d", next_pane_seq)
  local agent_name = (args.acp or {}).agent_name or "agent"
  local bufnr = create_transcript_buffer(pane_id, agent_name, args.transcript_path)
  pane_config[pane_id] = vim.tbl_extend("force", pane_config[pane_id] or {}, {
    source_winid = anchor_win,
    source_window_options = capture_window_options(anchor_win),
    pane_size = args.size,
    is_vertical = args.is_vertical == true,
    follow_output = true,
    buffer_background = args.acp and args.acp.buffer_background or nil,
    buffer_inactive_background = args.acp and args.acp.buffer_inactive_background or nil,
    transcript_max_lines = args.acp and args.acp.transcript_max_lines or nil,
  })

  vim.api.nvim_win_set_buf(win, bufnr)
  apply_transcript_window_opts(win, args.is_vertical, pane_config[pane_id])
  refresh_buffer_from_path(bufnr, args.transcript_path, { force = true })

  if anchor_win and anchor_win ~= win then
    pcall(vim.api.nvim_set_current_win, anchor_win)
  end

  if on_split then
    vim.schedule(function()
      on_split(pane_id, { bufnr = bufnr, winid = win, source_winid = anchor_win })
    end)
  end
end

function M.on_session_created(session)
  local bufnr = to_bufnr(session and session.pane_id)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(function()
      vim.b[bufnr].lazyagent_acp_pane_id = tostring(session.pane_id)
      vim.b[bufnr].lazyagent_acp_agent = session.agent_name
      vim.b[bufnr].lazyagent_acp_transcript_path = session.transcript_path
    end)
    refresh_buffer_layout(bufnr, { force_footer = true })
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
  local key = tostring(pane_id)
  local merged = vim.tbl_extend("force", pane_config[key] or {}, opts or {})
  local source_win = resolve_anchor_window(merged.source_winid)
  if source_win then
    merged.source_window_options = capture_window_options(source_win) or merged.source_window_options
  end
  pane_config[key] = merged
  if pane_config[key].follow_output == nil then
    pane_config[key].follow_output = true
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
  pane_buffers[tostring(pane_id)] = nil
  pane_config[tostring(pane_id)] = nil
  if not bufnr then
    return true
  end
  close_buffer_windows(bufnr)
  layout_state[tostring(bufnr)] = nil
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

function M.join_pane(pane_id, size, is_vertical, on_done, session)
  ensure_layout_autocmds()
  local bufnr = to_bufnr(pane_id)
  local pane_opts = pane_config[tostring(pane_id)] or {}
  local anchor_win = resolve_anchor_window(pane_opts.source_winid)
  local existing = bufnr and first_visible_window(bufnr) or nil
  if existing then
    pane_config[tostring(pane_id)] = vim.tbl_extend("force", pane_opts, {
      source_winid = anchor_win,
      source_window_options = capture_window_options(anchor_win) or pane_opts.source_window_options,
      pane_size = size or pane_opts.pane_size,
      is_vertical = is_vertical == true,
      buffer_background = pane_opts.buffer_background or (session and session.buffer_background) or nil,
      buffer_inactive_background = pane_opts.buffer_inactive_background
        or (session and session.buffer_inactive_background)
        or nil,
      transcript_max_lines = pane_opts.transcript_max_lines or (session and session.transcript_max_lines) or nil,
    })
    refresh_buffer_layout(bufnr, { force_footer = true })
    if on_done then
      vim.schedule(function()
        on_done(true)
      end)
    end
    return true
  end

  if not bufnr then
    if not session then
      if on_done then
        vim.schedule(function()
          on_done(false)
        end)
      end
      return false
    end
    bufnr = create_transcript_buffer(pane_id, session.agent_name, session.transcript_path)
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
  pane_config[tostring(pane_id)] = vim.tbl_extend("force", pane_config[tostring(pane_id)] or {}, {
    source_winid = anchor_win,
    source_window_options = capture_window_options(anchor_win) or pane_opts.source_window_options,
    pane_size = size or pane_opts.pane_size,
    is_vertical = is_vertical == true,
    follow_output = pane_opts.follow_output ~= false,
    buffer_background = pane_opts.buffer_background or (session and session.buffer_background) or nil,
    buffer_inactive_background = pane_opts.buffer_inactive_background
      or (session and session.buffer_inactive_background)
      or nil,
    transcript_max_lines = pane_opts.transcript_max_lines or (session and session.transcript_max_lines) or nil,
  })
  apply_transcript_window_opts(win, is_vertical, pane_config[tostring(pane_id)])
  refresh_buffer_from_path(bufnr, session and session.transcript_path or buffer_var(bufnr, "lazyagent_acp_transcript_path"))

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
