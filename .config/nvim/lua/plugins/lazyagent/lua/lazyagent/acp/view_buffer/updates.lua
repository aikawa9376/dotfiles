local M = {}

function M.new(ctx)
  local api = ctx.api
  local M = api
  local close_timer = ctx.close_timer
  local layout_entry = ctx.layout_entry
  local footer_padding_count = ctx.footer_padding_count
  local replace_buffer_lines = ctx.replace_buffer_lines
  local buffer_var = ctx.buffer_var
  local first_visible_window = ctx.first_visible_window
  local pane_opts_for_bufnr = ctx.pane_opts_for_bufnr
  local apply_transcript_window_opts = ctx.apply_transcript_window_opts
  local apply_transcript_buffer_opts = ctx.apply_transcript_buffer_opts
  local is_acp_buffer = ctx.is_acp_buffer
  local pause_follow_output = ctx.pause_follow_output
  local refresh_transcript_window = ctx.refresh_transcript_window
  local refresh_buffer_layout = ctx.refresh_buffer_layout
  local clear_transcript_window = ctx.clear_transcript_window
  local cleanup_markdown_rendering = ctx.cleanup_markdown_rendering
  local pane_buffers = ctx.pane_buffers
  local layout_state = ctx.layout_state
  local dedicated_transcript_windows = ctx.dedicated_transcript_windows
  local reset_appearance_cache = ctx.reset_appearance_cache
  local suppress_transcript_window_refresh = ctx.suppress_transcript_window_refresh
  local FOLLOW_SCROLL_OFF = ctx.follow_scroll_off
  local save_window_views = ctx.save_window_views
  local should_follow_output = ctx.should_follow_output
  local transcript_file_signature = ctx.transcript_file_signature
  local transcript_compaction_config = ctx.transcript_compaction_config
  local read_transcript_lines = ctx.read_transcript_lines
  local transcript_max_lines = ctx.transcript_max_lines
  local compact_transcript_lines = ctx.compact_transcript_lines
  local set_buffer_lines = ctx.set_buffer_lines
  local restore_window_views = ctx.restore_window_views
  local buffer_is_visible = ctx.buffer_is_visible
  local to_bufnr = ctx.to_bufnr
  local session_for_agent = ctx.session_for_agent
  local agent_name_for_bufnr = ctx.agent_name_for_bufnr
  local is_markdown_fence = ctx.is_markdown_fence
  local section_heading_for_line = ctx.section_heading_for_line
  local split_markdown_table_cells = ctx.split_markdown_table_cells
  local is_markdown_table_separator = ctx.is_markdown_table_separator
  local transcript_table_layout = ctx.transcript_table_layout
  local trailing_markdown_table_context = ctx.trailing_markdown_table_context
  local normalize_transcript_display = ctx.normalize_transcript_display
  local decorate_transcript_range = ctx.decorate_transcript_range
  local queue_markdown_rendering = ctx.queue_markdown_rendering
  local request_buffer_redraw = ctx.request_buffer_redraw or function(_) end
  local invalidate_transcript_section_cache = ctx.invalidate_transcript_section_cache or function(_) end
  local APPEND_BATCH_MS = ctx.append_batch_ms
  local ACP_TRANSCRIPT_FILETYPE = ctx.acp_transcript_filetype
  local smooth_scroll = require("lazyagent.acp.view_buffer.smooth_scroll")
  local diff_view = setmetatable({}, {
    __index = function(_, key)
      local view = ctx.diff_view and ctx.diff_view() or nil
      return view and view[key] or nil
    end,
  })
  local layout_autocmds_initialized = false
  local scroll_buffer_to_end
  local transcript_line_count
  local refresh_buffer_from_path
  local flush_pending_append
  local resume_deferred_updates_for_buffer
  local resume_deferred_transcript_updates

  local function pending_append_has_text(view_state)
    if type(view_state) ~= "table" then
      return false
    end
    if type(view_state.pending_append_chunks) == "table" and #view_state.pending_append_chunks > 0 then
      return true
    end
    return (view_state.pending_append or "") ~= ""
  end

  local function clear_pending_append(view_state)
    if type(view_state) ~= "table" then
      return
    end
    view_state.pending_append = ""
    view_state.pending_append_chunks = nil
    view_state.pending_append_size = 0
  end

  local function smooth_scroll_config(bufnr, mode)
    local opts = pane_opts_for_bufnr(bufnr) or {}
    return smooth_scroll.config(opts.smooth_scroll, mode)
  end

  local function push_pending_append(view_state, text)
    text = tostring(text or "")
    if text == "" then
      return
    end
    local chunks = view_state.pending_append_chunks
    if type(chunks) ~= "table" then
      chunks = {}
      if (view_state.pending_append or "") ~= "" then
        chunks[#chunks + 1] = view_state.pending_append
      end
      view_state.pending_append = ""
      view_state.pending_append_chunks = chunks
    end
    chunks[#chunks + 1] = text
    view_state.pending_append_size = (tonumber(view_state.pending_append_size) or 0) + #text
  end

  local function take_pending_append(view_state)
    if type(view_state) ~= "table" then
      return ""
    end
    local pending = view_state.pending_append or ""
    local chunks = view_state.pending_append_chunks
    if type(chunks) == "table" and #chunks > 0 then
      pending = pending ~= "" and (pending .. table.concat(chunks)) or table.concat(chunks)
    end
    clear_pending_append(view_state)
    return pending
  end

  local function shallow_table_copy(value)
    local out = {}
    if type(value) == "table" then
      for key, item in pairs(value) do
        out[key] = item
      end
    end
    return out
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
        if not bufnr or not is_acp_buffer(bufnr) then
          return
        end
        apply_transcript_buffer_opts(bufnr)
        for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
          refresh_transcript_window(bufnr, win)
        end
        pcall(resume_deferred_updates_for_buffer, bufnr, { refresh_layout = true })
      end,
    })

    vim.api.nvim_create_autocmd("BufEnter", {
      group = group,
      callback = function(args)
        local bufnr = tonumber(args.buf)
        if not bufnr or not is_acp_buffer(bufnr) then
          return
        end
        pause_follow_output(bufnr, { reason = "focus", win = vim.api.nvim_get_current_win() })
        refresh_transcript_window(bufnr, vim.api.nvim_get_current_win())
        pcall(resume_deferred_updates_for_buffer, bufnr, { refresh_layout = true })
      end,
    })

    vim.api.nvim_create_autocmd("WinEnter", {
      group = group,
      callback = function()
        local win = vim.api.nvim_get_current_win()
        local bufnr = vim.api.nvim_get_current_buf()
        if not is_acp_buffer(bufnr) then
          return
        end
        pause_follow_output(bufnr, { reason = "focus", win = win })
        refresh_transcript_window(bufnr, win)
        pcall(resume_deferred_updates_for_buffer, bufnr, { refresh_layout = true })
      end,
    })

    vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
      group = group,
      callback = function(args)
        local win = vim.api.nvim_get_current_win()
        local bufnr = tonumber(args.buf)
        if not bufnr and vim.api.nvim_win_is_valid(win) then
          bufnr = vim.api.nvim_win_get_buf(win)
        end
        if bufnr and is_acp_buffer(bufnr) then
          M._resume_follow_if_at_end(bufnr, win)
        end
      end,
    })

    vim.api.nvim_create_autocmd("WinScrolled", {
      group = group,
      callback = function(args)
        local win = tonumber(args.match) or vim.api.nvim_get_current_win()
        if not win or not vim.api.nvim_win_is_valid(win) then
          return
        end
        local bufnr = vim.api.nvim_win_get_buf(win)
        if is_acp_buffer(bufnr) then
          if smooth_scroll.active(win) then
            return
          end
          M._sync_follow_after_scroll(bufnr, win)
        end
      end,
    })

    vim.api.nvim_create_autocmd("CursorMoved", {
      group = group,
      callback = function(args)
        local bufnr = tonumber(args.buf)
        local win = vim.api.nvim_get_current_win()
        if bufnr and is_acp_buffer(bufnr) then
          if smooth_scroll.active(win) then
            return
          end
          M._sync_follow_after_cursor_moved(bufnr, win)
        end
      end,
    })

    vim.api.nvim_create_autocmd({ "FocusGained", "VimResume" }, {
      group = group,
      callback = function()
        vim.schedule(function()
          pcall(resume_deferred_transcript_updates)
        end)
      end,
    })

    vim.api.nvim_create_autocmd("OptionSet", {
      group = group,
      pattern = { "fillchars", "winhighlight", "foldenable", "foldmethod", "foldexpr", "foldcolumn" },
      callback = function()
        if suppress_transcript_window_refresh() then
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
        smooth_scroll.stop_for_buffer(bufnr)
        local pane_id = buffer_var(bufnr, "lazyagent_acp_pane_id")
        cleanup_markdown_rendering(bufnr)
        if pane_id ~= nil and pane_buffers[tostring(pane_id)] == bufnr then
          pane_buffers[tostring(pane_id)] = nil
        end
        layout_state[tostring(bufnr)] = nil
        for key, entry in pairs(dedicated_transcript_windows) do
          if entry.bufnr == bufnr or tostring(entry.pane_id or "") == tostring(pane_id or "") then
            dedicated_transcript_windows[key] = nil
          end
        end
      end,
    })

    vim.api.nvim_create_autocmd("WinClosed", {
      group = group,
      callback = function(args)
        local win = tonumber(args.match)
        smooth_scroll.stop_window(win)
        clear_transcript_window(win)
      end,
    })

    vim.api.nvim_create_autocmd("ColorScheme", {
      group = group,
      callback = function()
        reset_appearance_cache()
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
        local cfg = smooth_scroll_config(bufnr, "follow")
        local bottom = type(M._window_bottom_line) == "function" and M._window_bottom_line(win) or nil
        local delta = bottom and (row - bottom) or nil
        local function jump_to_end()
          vim.wo[win].scrolloff = FOLLOW_SCROLL_OFF
          pcall(vim.api.nvim_win_set_cursor, win, { row, col })
        end
        if cfg and delta and delta > 0 and delta <= cfg.max_delta then
          vim.wo[win].scrolloff = FOLLOW_SCROLL_OFF
          smooth_scroll.scroll_by_lines(win, delta, cfg, {
            bufnr = bufnr,
            mode = "follow",
            on_finish = function()
              if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
                jump_to_end()
              end
            end,
          })
        else
          pcall(jump_to_end)
        end
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

  local function append_crosses_markdown_fence_state(initial_state, text)
    local inside_fence = initial_state == true
    for _, line in ipairs(vim.split(tostring(text or ""), "\n", { plain = true })) do
      if section_heading_for_line(line) then
        if inside_fence then
          return true
        end
        inside_fence = false
      end
      if is_markdown_fence(line) then
        inside_fence = not inside_fence
      end
    end
    return false
  end

  local function advanced_markdown_fence_state(initial_state, lines)
    local inside_fence = initial_state == true
    lines = type(lines) == "table" and lines or {}
    for _, line in ipairs(lines) do
      if section_heading_for_line(line) then
        inside_fence = false
      end
      if is_markdown_fence(line) then
        inside_fence = not inside_fence
      end
    end
    return inside_fence
  end

  local function append_text_to_buffer(bufnr, text, opts)
    if not text or text == "" or not vim.api.nvim_buf_is_valid(bufnr) then
      return nil
    end
    opts = opts or {}

    local entry = layout_entry(bufnr)
    local current_display_meta = type(entry.transcript_display_meta) == "table" and entry.transcript_display_meta or {}
    local preserved_section_items = opts.preserve_display_metadata == true and entry.transcript_section_items or nil
    local preserved_display_meta = opts.preserve_display_metadata == true and current_display_meta or nil
    local metadata_lines = type(entry.metadata_source_lines) == "table"
        and vim.deepcopy(entry.metadata_source_lines)
      or vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local transcript_stop = transcript_line_count(bufnr)
    local replace_start = transcript_stop
    local current_last = ""
    local metadata_last = ""
    if transcript_stop > 0 then
      replace_start = transcript_stop - 1
      current_last = vim.api.nvim_buf_get_lines(bufnr, transcript_stop - 1, transcript_stop, false)[1] or ""
      metadata_last = metadata_lines[transcript_stop] or current_last
    end
    set_footer_padding(bufnr, 0)
    entry.footer_signature = nil
    local total_lines = vim.api.nvim_buf_line_count(bufnr)

    local chunks = vim.split(text, "\n", { plain = true })
    local first_chunk = table.remove(chunks, 1)
    local replacement = { current_last .. first_chunk }
    local metadata_replacement = { metadata_last .. first_chunk }
    vim.list_extend(replacement, chunks)
    vim.list_extend(metadata_replacement, chunks)

    local next_metadata_lines = {}
    for idx = 1, replace_start do
      next_metadata_lines[#next_metadata_lines + 1] = metadata_lines[idx]
    end
    vim.list_extend(next_metadata_lines, metadata_replacement)

    local next_meta = shallow_table_copy(current_display_meta)
    if type(preserved_display_meta) ~= "table" then
      next_meta.compacted = false
    end
    local previous_tail_lines = type(current_display_meta.table_tail_lines) == "table" and current_display_meta.table_tail_lines or {}
    local combined_tail = {}
    for _, line in ipairs(previous_tail_lines) do
      combined_tail[#combined_tail + 1] = line
    end
    vim.list_extend(combined_tail, replacement)
    local next_tail_context = trailing_markdown_table_context(combined_tail)
    next_meta.table_tail_state = next_tail_context.state
    next_meta.table_tail_lines = (next_tail_context.state == "header" or next_tail_context.state == "separator")
        and next_tail_context.lines
      or {}
    local prior_open_fence = current_display_meta.trailing_section_open_markdown_fence == true
    next_meta.trailing_section_open_markdown_fence = advanced_markdown_fence_state(prior_open_fence, replacement)
    entry.transcript_source_lines = nil
    entry.metadata_source_lines = next_metadata_lines
    entry.transcript_section_items = preserved_section_items or {}
    entry.transcript_display_meta = next_meta

    replace_buffer_lines(bufnr, replace_start, total_lines, replacement)
    invalidate_transcript_section_cache(bufnr)
    return replace_start
  end

  local function pending_transcript_section_count(text)
    local count = 0
    for _, line in ipairs(vim.split(tostring(text or ""), "\n", { plain = true })) do
      if section_heading_for_line(line) then
        count = count + 1
      end
    end
    return count
  end

  local function text_has_markdown_table_candidate(text)
    local lines = vim.split(tostring(text or ""), "\n", { plain = true })
    for idx, line in ipairs(lines) do
      local _, headers = split_markdown_table_cells(line)
      if headers and is_markdown_table_separator(lines[idx + 1], #headers) then
        return true
      end
      if is_markdown_table_separator(line) then
        return true
      end
    end
    return false
  end

  local function append_requires_full_refresh(bufnr, text)
    local entry = layout_entry(bufnr)
    local meta = type(entry.transcript_display_meta) == "table" and entry.transcript_display_meta or {}
    local cfg = transcript_compaction_config(bufnr)
    local pending_sections = pending_transcript_section_count(text)
    if pending_sections > 0 and type(meta.trailing_section_open_markdown_fence) ~= "boolean" then
      return true
    end
    local trailing_open_fence = meta.trailing_section_open_markdown_fence == true
    if pending_sections > 0 and append_crosses_markdown_fence_state(trailing_open_fence, text) then
      return true
    end

    local has_table_candidate = false
    if transcript_table_layout(bufnr) == "card" then
      local table_state = tostring(meta.table_tail_state or "none")
      if table_state == "rows" or text_has_markdown_table_candidate(text) then
        has_table_candidate = true
      elseif table_state == "header" or table_state == "separator" then
        local tail_context = type(meta.table_tail_lines) == "table" and meta.table_tail_lines or {}
        if #tail_context > 0 then
          local combined = vim.deepcopy(tail_context)
          vim.list_extend(combined, vim.split(tostring(text or ""), "\n", { plain = true }))
          has_table_candidate = text_has_markdown_table_candidate(table.concat(combined, "\n"))
        end
      end
    end
    if cfg.enabled then
      if meta.compacted == true then
        return pending_sections > 0 or has_table_candidate
      end
      local section_count = tonumber(meta.raw_section_count) or 0
      if section_count + pending_sections >= cfg.min_sections then
        return true
      end
    end

    return has_table_candidate
  end

  refresh_buffer_from_path = function(bufnr, transcript_path, opts)
    opts = opts or {}
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return false
    end

    local entry = layout_entry(bufnr)
    local saved_views = nil
    if opts.preserve_view ~= false and not should_follow_output(bufnr) then
      saved_views = save_window_views(bufnr)
    end
    local signature = transcript_file_signature(transcript_path)
    if not opts.force and entry.transcript_file_signature == signature then
      entry.pending_full_refresh = false
      entry.pending_deferred_refresh = false
      entry.pending_deferred_changed_start = nil
      refresh_buffer_layout(bufnr, opts.layout or {})
      restore_window_views(bufnr, saved_views)
      return false
    end

    local lines = read_transcript_lines(transcript_path, transcript_max_lines(bufnr))
    local display_lines, section_items, display_meta = compact_transcript_lines(bufnr, lines)

    set_buffer_lines(bufnr, display_lines, section_items, display_meta)
    entry.pending_full_refresh = false
    entry.pending_deferred_refresh = false
    entry.pending_deferred_changed_start = nil
    entry.transcript_file_signature = signature
    refresh_buffer_layout(bufnr, { force_decorate = true, force_footer = true })
    restore_window_views(bufnr, saved_views)
    request_buffer_redraw(bufnr)
    return true
  end

  local function refresh_buffer_from_file(session)
    local bufnr = to_bufnr(session and session.pane_id)
    if not bufnr then
      return
    end

    session.view_state = session.view_state or {}
    local view_state = session.view_state
    if view_state.refresh_pending then
      return
    end
    view_state.refresh_pending = true

    vim.schedule(function()
      view_state.refresh_pending = false
      if not vim.api.nvim_buf_is_valid(bufnr) then
        view_state.force_full_refresh = false
        return
      end

      if not buffer_is_visible(bufnr) then
        layout_entry(bufnr).pending_full_refresh = true
        view_state.force_full_refresh = false
        return
      end

      refresh_buffer_from_path(bufnr, session.transcript_path)
      view_state.force_full_refresh = false
    end)
  end

  local function clear_deferred_incremental_refresh(bufnr)
    local entry = layout_entry(bufnr)
    entry.pending_deferred_refresh = false
    entry.pending_deferred_changed_start = nil
  end

  local function mark_deferred_incremental_refresh(bufnr, changed_start)
    local entry = layout_entry(bufnr)
    entry.pending_deferred_refresh = true
    if type(changed_start) == "number" then
      local current = tonumber(entry.pending_deferred_changed_start)
      entry.pending_deferred_changed_start = current and math.min(current, changed_start) or changed_start
    end
  end

  local function buffer_has_deferred_updates(bufnr)
    local entry = layout_state[tostring(bufnr)]
    if type(entry) == "table" and (entry.pending_full_refresh or entry.pending_deferred_refresh) then
      return true
    end

    local session = session_for_agent(agent_name_for_bufnr(bufnr))
    return session and pending_append_has_text(session.view_state)
  end

  local function apply_pending_append(bufnr, pending)
    local entry = layout_entry(bufnr)
    local meta = type(entry.transcript_display_meta) == "table" and entry.transcript_display_meta or {}
    local pending_sections = pending_transcript_section_count(pending)
    if append_requires_full_refresh(bufnr, pending) then
      return nil, pending_sections, true
    end

    local preserve_display_metadata = meta.compacted == true and pending_sections == 0
    local changed_start = append_text_to_buffer(bufnr, pending, {
      preserve_display_metadata = preserve_display_metadata,
    })

    if changed_start ~= nil then
      meta = type(entry.transcript_display_meta) == "table" and entry.transcript_display_meta or {}
      meta.raw_section_count = (tonumber(meta.raw_section_count) or 0) + pending_sections
      if pending_sections > 0 then
        meta.pinned_rows = nil
      end
      entry.transcript_display_meta = meta
    end

    return changed_start, pending_sections, false
  end

  flush_pending_append = function(session, opts)
    opts = opts or {}
    local bufnr = to_bufnr(session and session.pane_id)
    if not bufnr then
      return false
    end

    session.view_state = session.view_state or {}
    close_timer(session.view_state.append_timer)
    session.view_state.append_timer = nil

    if not vim.api.nvim_buf_is_valid(bufnr) then
      clear_pending_append(session.view_state)
      return false
    end

    local pending = take_pending_append(session.view_state)
    if pending == "" then
      return false
    end

    local visible = buffer_is_visible(bufnr)
    local changed_start = nil
    local needs_full_refresh = false

    if not visible and opts.allow_hidden_incremental ~= true then
      local entry = layout_entry(bufnr)
      entry.pending_full_refresh = true
      clear_deferred_incremental_refresh(bufnr)
      return false
    end

    changed_start, _, needs_full_refresh = apply_pending_append(bufnr, pending)
    if needs_full_refresh then
      if visible then
        refresh_buffer_from_path(bufnr, session.transcript_path, { force = true })
        return true
      end
      local entry = layout_entry(bufnr)
      entry.pending_full_refresh = true
      clear_deferred_incremental_refresh(bufnr)
      return false
    end

    local max_lines = transcript_max_lines(bufnr)
    if max_lines and max_lines > 0 and transcript_line_count(bufnr) > (max_lines + 1) then
      if visible then
        refresh_buffer_from_path(bufnr, session.transcript_path)
        return true
      end
      local entry = layout_entry(bufnr)
      entry.pending_full_refresh = true
      clear_deferred_incremental_refresh(bufnr)
      return false
    end

    local entry = layout_entry(bufnr)
    entry.pending_full_refresh = false
    entry.transcript_file_signature = transcript_file_signature(session.transcript_path)

    if not visible then
      if changed_start ~= nil then
        mark_deferred_incremental_refresh(bufnr, changed_start)
      end
      return changed_start ~= nil
    end

    if entry.pending_deferred_refresh then
      clear_deferred_incremental_refresh(bufnr)
      refresh_buffer_layout(bufnr, { force_decorate = true, force_footer = true })
      request_buffer_redraw(bufnr)
      return true
    end

    clear_deferred_incremental_refresh(bufnr)
    if changed_start ~= nil then
      local display_start = normalize_transcript_display(bufnr, changed_start)
      if type(display_start) == "number" then
        changed_start = math.min(changed_start, display_start)
      end
      decorate_transcript_range(bufnr, changed_start, transcript_line_count(bufnr))
      diff_view.decorate_diff_blocks(bufnr)
      queue_markdown_rendering(bufnr)
      M.refresh_footer(bufnr)
      if should_follow_output(bufnr) then
        scroll_buffer_to_end(bufnr)
      end
      request_buffer_redraw(bufnr)
      return true
    end
    return false
  end

  resume_deferred_updates_for_buffer = function(bufnr, opts)
    opts = opts or {}
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return false
    end

    local session = session_for_agent(agent_name_for_bufnr(bufnr))
    if session and pending_append_has_text(session.view_state) then
      return flush_pending_append(session, {
        allow_hidden_incremental = opts.allow_hidden_incremental == true,
      })
    end

    local entry = layout_entry(bufnr)
    if entry.pending_full_refresh then
      local transcript_path = (session and session.transcript_path) or buffer_var(bufnr, "lazyagent_acp_transcript_path")
      if transcript_path and transcript_path ~= "" then
        refresh_buffer_from_path(bufnr, transcript_path, { force = true })
        return true
      end
      entry.pending_full_refresh = false
    end

    if entry.pending_deferred_refresh and buffer_is_visible(bufnr) then
      clear_deferred_incremental_refresh(bufnr)
      refresh_buffer_layout(bufnr, { force_decorate = true, force_footer = true })
      request_buffer_redraw(bufnr)
      return true
    end

    if opts.refresh_layout == true and buffer_is_visible(bufnr) then
      return refresh_buffer_layout(bufnr, { check_footer = true })
    end

    return false
  end

  resume_deferred_transcript_updates = function()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if buffer_var(bufnr, "lazyagent_acp_pane_id") ~= nil
        and buffer_is_visible(bufnr)
        and buffer_has_deferred_updates(bufnr)
      then
        pcall(resume_deferred_updates_for_buffer, bufnr, { refresh_layout = true })
      end
    end
  end

  local function queue_append(session, text)
    local bufnr = to_bufnr(session and session.pane_id)
    if not bufnr then
      return
    end

    session.view_state = session.view_state or {}
    push_pending_append(session.view_state, text)

    if session.view_state.append_timer then
      return
    end

    local uv = vim.uv or vim.loop
    if not uv or not uv.new_timer then
      vim.schedule(function()
        flush_pending_append(session, { allow_hidden_incremental = true })
      end)
      return
    end

    local timer = uv.new_timer()
    session.view_state.append_timer = timer
    timer:start(APPEND_BATCH_MS, 0, vim.schedule_wrap(function()
      flush_pending_append(session, { allow_hidden_incremental = true })
    end))
  end

  return {
    set_footer_padding = set_footer_padding,
    ensure_layout_autocmds = ensure_layout_autocmds,
    scroll_buffer_to_end = scroll_buffer_to_end,
    transcript_line_count = transcript_line_count,
    refresh_buffer_from_path = refresh_buffer_from_path,
    refresh_buffer_from_file = refresh_buffer_from_file,
    flush_pending_append = flush_pending_append,
    resume_deferred_updates_for_buffer = resume_deferred_updates_for_buffer,
    resume_deferred_transcript_updates = resume_deferred_transcript_updates,
    queue_append = queue_append,
  }
end

return M
