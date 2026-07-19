local M = {}

function M.new(ctx)
  local api = ctx.api
  local pane_config = ctx.pane_config
  local pane_buffers = ctx.pane_buffers
  local layout_state = ctx.layout_state
  local dedicated_transcript_windows = ctx.dedicated_transcript_windows
  local redirecting_transcript_windows = ctx.redirecting_transcript_windows
  local ACP_WINDOW_OPTIONS = ctx.acp_window_options
  local custom_background_groups = ctx.custom_background_groups
  local set_suppress_transcript_window_refresh = ctx.set_suppress_transcript_window_refresh
  local FOLLOW_SCROLL_OFF = ctx.follow_scroll_off
  local DEFAULT_SCROLL_OFF = ctx.default_scroll_off
  local ACP_TRANSCRIPT_FILETYPE = ctx.acp_transcript_filetype
  local cleanup_markdown_rendering = ctx.cleanup_markdown_rendering
  local is_metadata_popup_buffer = ctx.is_metadata_popup_buffer
  local line_has_heading = ctx.line_has_heading
  local jump_window_to_row = ctx.jump_window_to_row
  local transcript_line_count = ctx.transcript_line_count
  local code_block_target_row = ctx.code_block_target_row
  local transcript_source_lines = ctx.transcript_source_lines
  local scroll_buffer_to_end = ctx.scroll_buffer_to_end
  local show_action_menu = ctx.show_action_menu
  local show_metadata_popup = ctx.show_metadata_popup
  local notify_transcript_read = ctx.notify_transcript_read or function() end
  local diff_view = setmetatable({}, {
    __index = function(_, key)
      local view = ctx.diff_view and ctx.diff_view() or nil
      return view and view[key] or nil
    end,
  })

  local M = api
  local pane_id_for_bufnr
  local agent_name_for_bufnr
  local fancy_mode_enabled
  local layout_entry
  local set_window_size
  local first_visible_window
  local buffer_is_visible
  local transcript_max_lines

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

  pane_id_for_bufnr = function(bufnr)
    return buffer_var(bufnr, "lazyagent_acp_pane_id") or bufnr
  end

  agent_name_for_bufnr = function(bufnr)
    return buffer_var(bufnr, "lazyagent_acp_agent")
  end

  local function pane_opts_for_bufnr(bufnr)
    return pane_config[tostring(pane_id_for_bufnr(bufnr))] or {}
  end

  local function transcript_table_layout(bufnr)
    local opts = pane_opts_for_bufnr(bufnr)
    local layout = tostring(opts and opts.table_layout or ""):lower()
    if layout == "card" then
      return "card"
    end
    return "table"
  end

  fancy_mode_enabled = function(bufnr_or_pane_id)
    local opts
    if type(bufnr_or_pane_id) == "number" and vim.api.nvim_buf_is_valid(bufnr_or_pane_id) then
      opts = pane_opts_for_bufnr(bufnr_or_pane_id)
    else
      opts = pane_config[tostring(bufnr_or_pane_id or "")]
    end
    return type(opts) == "table" and opts.fancy_mode == true
  end

  local function should_release_buffer_on_hide(bufnr_or_pane_id)
    local opts
    if type(bufnr_or_pane_id) == "number" and vim.api.nvim_buf_is_valid(bufnr_or_pane_id) then
      opts = pane_opts_for_bufnr(bufnr_or_pane_id)
    else
      opts = pane_config[tostring(bufnr_or_pane_id or "")]
    end
    return type(opts) == "table" and opts.release_buffer_on_hide == true
  end

  local function resolve_release_buffer_on_hide(pane_opts, session)
    if type(pane_opts) == "table" and pane_opts.release_buffer_on_hide ~= nil then
      return pane_opts.release_buffer_on_hide == true
    end
    return session and session.release_buffer_on_hide == true or false
  end

  local function is_acp_buffer(bufnr)
    return buffer_var(bufnr, "lazyagent_acp_pane_id") ~= nil
  end

  local function in_cmdline_mode()
    local ok, mode = pcall(vim.api.nvim_get_mode)
    local current_mode = ok and mode and mode.mode or ""
    return type(current_mode) == "string" and current_mode:sub(1, 1) == "c"
  end

  local function redirectable_buffer(bufnr)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or is_acp_buffer(bufnr) then
      return false
    end
    local buftype = vim.bo[bufnr].buftype
    return buftype == "" or buftype == "acwrite"
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
    if in_cmdline_mode() then
      return false
    end
    if is_metadata_popup_buffer(bufnr) then
      return false
    end
    local tracked = tracked_transcript_window(win)
    if tracked == nil or tracked.bufnr == bufnr then
      return false
    end
    if not redirectable_buffer(bufnr) then
      return false
    end
    if vim.api.nvim_win_get_buf(win) ~= bufnr then
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

  function M._follow_auto_resume_enabled(bufnr)
    return buffer_var(bufnr, "lazyagent_acp_fullscreen_transcript") ~= true
  end

  local function set_follow_output(bufnr, enabled, opts)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return false
    end
    opts = opts or {}
    local pane_id = tostring(pane_id_for_bufnr(bufnr))
    local current_config = pane_config[pane_id] or {}
    local was_following = current_config.follow_output ~= false
    local next_config = vim.tbl_extend("force", current_config, {
      follow_output = enabled ~= false,
    })
    if enabled ~= false then
      next_config.follow_pause_reason = nil
      next_config.follow_pause_win = nil
      next_config.follow_pause_topline = nil
      next_config.follow_pause_cursor_left_end = nil
    else
      next_config.follow_pause_reason = opts.reason or "manual"
      next_config.follow_pause_win = opts.win
      next_config.follow_pause_topline = opts.topline or (opts.win and M._window_topline(opts.win) or nil)
      local cursor_left_end = opts.win and not M._window_cursor_reaches_transcript_end(opts.win, bufnr) or false
      if was_following then
        next_config.follow_pause_cursor_left_end = cursor_left_end
      elseif cursor_left_end then
        next_config.follow_pause_cursor_left_end = true
      end
    end
    pane_config[pane_id] = next_config
    for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
      if vim.api.nvim_win_is_valid(win) then
        vim.wo[win].scrolloff = (enabled ~= false) and FOLLOW_SCROLL_OFF or DEFAULT_SCROLL_OFF
      end
    end
    return true
  end

  local function pause_follow_output(bufnr, opts)
    opts = opts or {}
    if not bufnr or not is_acp_buffer(bufnr) then
      return false
    end
    if not should_follow_output(bufnr) then
      if opts.reason then
        set_follow_output(bufnr, false, opts)
        if type(M.refresh_footer) == "function" then
          M.refresh_footer(bufnr)
        end
      end
      return false
    end
    set_follow_output(bufnr, false, opts)
    if type(M.refresh_footer) == "function" then
      M.refresh_footer(bufnr)
    end
    return true
  end

  function M._transcript_end_line(bufnr)
    local buffer_stop = math.max(1, vim.api.nvim_buf_line_count(bufnr))
    local transcript_stop = transcript_line_count and transcript_line_count(bufnr) or buffer_stop
    if transcript_stop and transcript_stop > 0 then
      return math.min(buffer_stop, transcript_stop)
    end
    return buffer_stop
  end

  local function window_info(win)
    if not win or not vim.api.nvim_win_is_valid(win) then
      return nil
    end
    local ok, info = pcall(vim.fn.getwininfo, win)
    local entry = ok and type(info) == "table" and info[1] or nil
    if type(entry) ~= "table" then
      return nil
    end
    return entry
  end

  function M._window_bottom_line(win)
    local info = window_info(win)
    return info and tonumber(info.botline) or nil
  end

  function M._window_topline(win)
    local info = window_info(win)
    return info and tonumber(info.topline) or nil
  end

  function M._window_view_reaches_transcript_end(win, bufnr)
    if not win or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= bufnr then
      return false
    end
    local bottom = M._window_bottom_line(win)
    return bottom ~= nil and bottom >= M._transcript_end_line(bufnr)
  end

  function M._window_cursor_reaches_transcript_end(win, bufnr)
    if not win or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= bufnr then
      return false
    end
    local ok, cursor = pcall(vim.api.nvim_win_get_cursor, win)
    return ok and type(cursor) == "table" and tonumber(cursor[1]) and cursor[1] >= M._transcript_end_line(bufnr)
  end

  function M._window_at_transcript_end(win, bufnr)
    return M._window_cursor_reaches_transcript_end(win, bufnr) or M._window_view_reaches_transcript_end(win, bufnr)
  end

  function M._any_window_at_transcript_end(bufnr)
    for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
      if M._window_at_transcript_end(win, bufnr) then
        return true
      end
    end
    return false
  end

  function M._any_window_cursor_reaches_transcript_end(bufnr)
    for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
      if M._window_cursor_reaches_transcript_end(win, bufnr) then
        return true
      end
    end
    return false
  end

  function M._transcript_is_read(bufnr)
    return bufnr ~= nil
      and vim.api.nvim_buf_is_valid(bufnr)
      and is_acp_buffer(bufnr)
      and buffer_is_visible(bufnr)
      and should_follow_output(bufnr)
      and M._any_window_at_transcript_end(bufnr)
  end

  function M._notify_transcript_read(bufnr)
    if not M._transcript_is_read(bufnr) then
      return false
    end
    notify_transcript_read(pane_id_for_bufnr(bufnr))
    return true
  end

  function M._resume_follow_output(bufnr, opts)
    opts = opts or {}
    if not bufnr or not is_acp_buffer(bufnr) then
      return false
    end
    set_follow_output(bufnr, true)
    if type(M.refresh_footer) == "function" then
      M.refresh_footer(bufnr)
    end
    if opts.scroll ~= false and scroll_buffer_to_end then
      scroll_buffer_to_end(bufnr)
    end
    return true
  end

  function M._resume_follow_if_at_end(bufnr, win, opts)
    opts = opts or {}
    if not M._follow_auto_resume_enabled(bufnr) or should_follow_output(bufnr) then
      return false
    end
    local pane_opts = pane_opts_for_bufnr(bufnr)
    local allow_view_end = opts.allow_view_end == true or pane_opts.follow_pause_reason ~= "manual"
    if
      pane_opts.follow_pause_reason == "manual"
      and opts.allow_view_end ~= true
      and pane_opts.follow_pause_cursor_left_end ~= true
    then
      return false
    end
    local at_end = false
    if allow_view_end then
      at_end = (win and M._window_at_transcript_end(win, bufnr)) or M._any_window_at_transcript_end(bufnr)
    else
      at_end = (win and M._window_cursor_reaches_transcript_end(win, bufnr))
        or M._any_window_cursor_reaches_transcript_end(bufnr)
    end
    if at_end then
      local resumed = M._resume_follow_output(bufnr, opts)
      M._notify_transcript_read(bufnr)
      return resumed
    end
    return false
  end

  function M._sync_follow_after_scroll(bufnr, win)
    if not bufnr or not is_acp_buffer(bufnr) or not M._follow_auto_resume_enabled(bufnr) then
      return false
    end
    if M._window_view_reaches_transcript_end(win, bufnr) then
      if should_follow_output(bufnr) then
        M._notify_transcript_read(bufnr)
        return false
      end

      local pane_opts = pane_opts_for_bufnr(bufnr)
      local current_topline = M._window_topline(win)
      local paused_topline = tonumber(pane_opts.follow_pause_topline)
      if not current_topline or not paused_topline or current_topline <= paused_topline then
        pause_follow_output(bufnr, { reason = "manual", win = win, topline = current_topline })
        return false
      end

      return M._resume_follow_if_at_end(bufnr, win, { allow_view_end = true })
    end
    return pause_follow_output(bufnr, { reason = "manual", win = win })
  end

  function M._sync_follow_after_cursor_moved(bufnr, win)
    if not bufnr or not is_acp_buffer(bufnr) or not M._follow_auto_resume_enabled(bufnr) then
      return false
    end
    if should_follow_output(bufnr) and not M._window_view_reaches_transcript_end(win, bufnr) then
      return pause_follow_output(bufnr, { reason = "manual", win = win })
    end
    if should_follow_output(bufnr) then
      M._notify_transcript_read(bufnr)
    end
    if not should_follow_output(bufnr) then
      local pane_opts = pane_opts_for_bufnr(bufnr)
      if not M._window_cursor_reaches_transcript_end(win, bufnr) then
        pane_opts.follow_pause_cursor_left_end = true
        return false
      end
      if pane_opts.follow_pause_cursor_left_end == true then
        local resumed = M._resume_follow_output(bufnr)
        M._notify_transcript_read(bufnr)
        return resumed
      end
    end
    return false
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
      set_suppress_transcript_window_refresh(true)
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
      pcall(function()
        vim.wo[win].smoothscroll = true
      end)
      vim.wo[win].statusline = ""
      vim.wo[win].eventignorewin = ""
      hide_end_of_buffer_fill(win)
    end)
    pcall(apply_transcript_background, win, appearance)
    local bufnr = vim.api.nvim_win_get_buf(win)
    track_transcript_window(win, pane_id_for_bufnr(bufnr), bufnr)
    set_suppress_transcript_window_refresh(false)
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
      vim.bo[bufnr].filetype = ACP_TRANSCRIPT_FILETYPE
      vim.bo[bufnr].swapfile = false
      vim.bo[bufnr].undofile = false
      vim.bo[bufnr].undolevels = -1
      vim.bo[bufnr].buflisted = false
      vim.b[bufnr].lazyagent_acp_transcript = true
      vim.b[bufnr].illuminate_disable = true
      vim.b[bufnr].matchup_matchparen_enabled = 0
    end)
    pcall(vim.api.nvim_set_option_value, "spell", false, { buf = bufnr })

    -- Buffer-local mappings: jump between User sections and fenced code blocks.
    local function jump_to_row(win, row)
      jump_window_to_row(win, row)
    end

    local function jump_to_user(forward)
      if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      local win = vim.api.nvim_get_current_win()
      local cur = vim.api.nvim_win_get_cursor(win)
      local cur_row = cur[1]
      local stop = transcript_line_count(bufnr)
      if forward then
        for r = cur_row + 1, stop do
          local line = vim.api.nvim_buf_get_lines(bufnr, r - 1, r, false)[1] or ""
          if line_has_heading(line, "User") then
            jump_to_row(win, r)
            return
          end
        end
        vim.notify("No later User section", vim.log.levels.INFO)
      else
        for r = math.max(1, cur_row - 1), 1, -1 do
          local line = vim.api.nvim_buf_get_lines(bufnr, r - 1, r, false)[1] or ""
          if line_has_heading(line, "User") then
            jump_to_row(win, r)
            return
          end
        end
        vim.notify("No earlier User section", vim.log.levels.INFO)
      end
    end

    local function jump_to_code_block(forward)
      if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      local win = vim.api.nvim_get_current_win()
      local cur = vim.api.nvim_win_get_cursor(win)
      local cur_row = cur[1]
      local stop = transcript_line_count(bufnr)
      local target = code_block_target_row(
        transcript_source_lines(bufnr, 0, stop),
        cur_row,
        forward
      )
      if target then
        jump_to_row(win, target)
        return
      end
      vim.notify(forward and "No later code block" or "No earlier code block", vim.log.levels.INFO)
    end

    pcall(function()
      vim.keymap.set("n", "]]", function()
        jump_to_user(true)
      end, { buffer = bufnr, noremap = true, silent = true, desc = "LazyAgentACP: next User" })
      vim.keymap.set("n", "[[", function()
        jump_to_user(false)
      end, { buffer = bufnr, noremap = true, silent = true, desc = "LazyAgentACP: prev User" })
      vim.keymap.set("n", "]d", function()
        jump_to_code_block(true)
      end, { buffer = bufnr, noremap = true, silent = true, desc = "LazyAgentACP: next code block" })
      vim.keymap.set("n", "[d", function()
        jump_to_code_block(false)
      end, { buffer = bufnr, noremap = true, silent = true, desc = "LazyAgentACP: prev code block" })
      vim.keymap.set("n", "<C-u>", function()
        M.scroll_up(pane_id_for_bufnr(bufnr))
      end, { buffer = bufnr, noremap = true, silent = true, desc = "LazyAgentACP: half page up" })
      vim.keymap.set("n", "<C-d>", function()
        M.scroll_down(pane_id_for_bufnr(bufnr))
      end, { buffer = bufnr, noremap = true, silent = true, desc = "LazyAgentACP: half page down" })
      vim.keymap.set("n", "<C-b>", function()
        M.scroll_page_up(pane_id_for_bufnr(bufnr))
      end, { buffer = bufnr, noremap = true, silent = true, desc = "LazyAgentACP: page up" })
      vim.keymap.set("n", "<C-f>", function()
        M.scroll_page_down(pane_id_for_bufnr(bufnr))
      end, { buffer = bufnr, noremap = true, silent = true, desc = "LazyAgentACP: page down" })
      vim.keymap.set("n", "<PageUp>", function()
        M.scroll_page_up(pane_id_for_bufnr(bufnr))
      end, { buffer = bufnr, noremap = true, silent = true, desc = "LazyAgentACP: page up" })
      vim.keymap.set("n", "<PageDown>", function()
        M.scroll_page_down(pane_id_for_bufnr(bufnr))
      end, { buffer = bufnr, noremap = true, silent = true, desc = "LazyAgentACP: page down" })
      vim.keymap.set("n", "G", function()
        M.resume_follow(pane_id_for_bufnr(bufnr))
      end, { buffer = bufnr, noremap = true, silent = true, desc = "LazyAgentACP: jump to end and follow" })
      vim.keymap.set("n", "<End>", function()
        M.resume_follow(pane_id_for_bufnr(bufnr))
      end, { buffer = bufnr, noremap = true, silent = true, desc = "LazyAgentACP: jump to end and follow" })
      vim.keymap.set("n", "<CR>", function()
        if diff_view and type(diff_view.open_diff_block_under_cursor) == "function" then
          local ok, opened = pcall(diff_view.open_diff_block_under_cursor, bufnr)
          if ok and opened then
            return
          end
          if not ok then
            vim.notify("LazyAgentACP: failed to open diff block", vim.log.levels.WARN)
            return
          end
        end
        vim.cmd("normal! <CR>")
      end, { buffer = bufnr, noremap = true, silent = true, desc = "LazyAgentACP: open diff block" })
      vim.keymap.set("n", "ga", function()
        show_action_menu(vim.api.nvim_get_current_buf())
      end, { buffer = bufnr, noremap = true, silent = true, desc = "LazyAgentACP: actions" })
      vim.keymap.set("n", "<Space><Space>", function()
        show_metadata_popup(vim.api.nvim_get_current_buf())
      end, { buffer = bufnr, noremap = true, silent = true, desc = "LazyAgentACP: show metadata" })
      vim.keymap.set("n", "<LocalLeader>s", function()
        require("lazyagent.logic.session").switch_acp_provider(agent_name_for_bufnr(vim.api.nvim_get_current_buf()))
      end, { buffer = bufnr, noremap = true, silent = true, desc = "LazyAgentACP: switch provider" })
    end)

  end

  local function close_buffer_windows(bufnr)
    for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
      if vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
  end

  local function save_window_views(bufnr)
    local views = {}
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return views
    end

    for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
      if vim.api.nvim_win_is_valid(win) then
        local ok, view = pcall(vim.api.nvim_win_call, win, function()
          return vim.fn.winsaveview()
        end)
        if ok and type(view) == "table" then
          views[tostring(win)] = view
        end
      end
    end
    return views
  end

  local function restore_window_views(bufnr, views)
    if type(views) ~= "table" or not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end

    local line_count = math.max(1, vim.api.nvim_buf_line_count(bufnr))
    for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
      local view = views[tostring(win)]
      if vim.api.nvim_win_is_valid(win) and type(view) == "table" and vim.api.nvim_win_get_buf(win) == bufnr then
        pcall(vim.api.nvim_win_call, win, function()
          local restored = vim.deepcopy(view)
          restored.lnum = math.min(math.max(1, tonumber(restored.lnum) or 1), line_count)
          restored.topline = math.min(math.max(1, tonumber(restored.topline) or 1), line_count)
          vim.fn.winrestview(restored)
        end)
      end
    end
  end

  local function release_transcript_buffer(pane_id, bufnr)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return false
    end
    cleanup_markdown_rendering(bufnr)
    layout_state[tostring(bufnr)] = nil
    if pane_buffers[tostring(pane_id)] == bufnr then
      pane_buffers[tostring(pane_id)] = nil
    end
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    return true
  end

  local function create_transcript_buffer(pane_id, agent_name, transcript_path, source_bufnr)
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
      if source_bufnr and vim.api.nvim_buf_is_valid(source_bufnr) then
        vim.b[bufnr].lazyagent_source_bufnr = source_bufnr
      end
    end)
    apply_transcript_buffer_opts(bufnr)

    pane_buffers[pane_key] = bufnr
    return bufnr
  end

  local function adopt_transcript_buffer(pane_id, agent_name, transcript_path, switch_view, source_bufnr)
    if type(switch_view) ~= "table" then
      return nil
    end

    local bufnr = tonumber(switch_view.bufnr)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return nil
    end

    local pane_key = tostring(pane_id)
    local old_pane_key = tostring(switch_view.pane_id or buffer_var(bufnr, "lazyagent_acp_pane_id") or "")
    if old_pane_key ~= "" then
      if pane_buffers[old_pane_key] == bufnr then
        pane_buffers[old_pane_key] = nil
      end
      pane_config[old_pane_key] = nil
    end

    local safe_agent_name = tostring(agent_name or "agent"):gsub("[^%w-_]+", "-")
    pcall(function()
      vim.api.nvim_buf_set_name(bufnr, "")
      vim.api.nvim_buf_set_name(bufnr, string.format("lazyagent://acp/%s-%s", safe_agent_name, pane_key))
      vim.b[bufnr].lazyagent_acp_transcript = true
      vim.bo[bufnr].filetype = ACP_TRANSCRIPT_FILETYPE
      vim.b[bufnr].lazyagent_acp_pane_id = pane_key
      vim.b[bufnr].lazyagent_acp_agent = agent_name
      vim.b[bufnr].lazyagent_acp_transcript_path = transcript_path
      if source_bufnr and vim.api.nvim_buf_is_valid(source_bufnr) then
        vim.b[bufnr].lazyagent_source_bufnr = source_bufnr
      end
    end)

    local entry = layout_entry(bufnr)
    entry.footer_signature = nil
    entry.pending_full_refresh = false
    entry.transcript_file_signature = nil

    pane_buffers[pane_key] = bufnr
    apply_transcript_buffer_opts(bufnr)
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

  transcript_max_lines = function(bufnr)
    local opts = pane_opts_for_bufnr(bufnr)
    local value = tonumber(opts and opts.transcript_max_lines)
    if value and value > 0 then
      return math.floor(value)
    end
    return nil
  end

  return {
    is_normal_window = is_normal_window,
    resolve_anchor_window = resolve_anchor_window,
    to_bufnr = to_bufnr,
    buffer_var = buffer_var,
    pane_id_for_bufnr = pane_id_for_bufnr,
    agent_name_for_bufnr = agent_name_for_bufnr,
    pane_opts_for_bufnr = pane_opts_for_bufnr,
    transcript_table_layout = transcript_table_layout,
    fancy_mode_enabled = fancy_mode_enabled,
    should_release_buffer_on_hide = should_release_buffer_on_hide,
    resolve_release_buffer_on_hide = resolve_release_buffer_on_hide,
    is_acp_buffer = is_acp_buffer,
    tracked_transcript_window = tracked_transcript_window,
    track_transcript_window = track_transcript_window,
    clear_transcript_window = clear_transcript_window,
    capture_window_options = capture_window_options,
    redirect_buffer_from_transcript_window = redirect_buffer_from_transcript_window,
    layout_entry = layout_entry,
    footer_padding_count = footer_padding_count,
    should_follow_output = should_follow_output,
    set_follow_output = set_follow_output,
    pause_follow_output = pause_follow_output,
    set_window_size = set_window_size,
    apply_transcript_window_opts = apply_transcript_window_opts,
    refresh_transcript_window = refresh_transcript_window,
    apply_transcript_buffer_opts = apply_transcript_buffer_opts,
    close_buffer_windows = close_buffer_windows,
    save_window_views = save_window_views,
    restore_window_views = restore_window_views,
    release_transcript_buffer = release_transcript_buffer,
    create_transcript_buffer = create_transcript_buffer,
    adopt_transcript_buffer = adopt_transcript_buffer,
    first_visible_window = first_visible_window,
    buffer_is_visible = buffer_is_visible,
    transcript_max_lines = transcript_max_lines,
  }
end

return M
