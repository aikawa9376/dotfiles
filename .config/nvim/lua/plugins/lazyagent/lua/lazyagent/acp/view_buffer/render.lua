local M = {}

function M.new(ctx)
  local section_heading_for_line = ctx.section_heading_for_line
  local replace_heading_token = ctx.replace_heading_token
  local FANCY_SECTION_LABELS = ctx.fancy_section_labels
  local first_visible_window = ctx.first_visible_window
  local fancy_mode_enabled = ctx.fancy_mode_enabled
  local strdisplaywidth = ctx.strdisplaywidth
  local layout_entry = ctx.layout_entry
  local transcript_line_count = ctx.transcript_line_count
  local replace_buffer_lines = ctx.replace_buffer_lines
  local buffer_is_visible = ctx.buffer_is_visible
  local pinned_section_rows = ctx.pinned_section_rows
  local line_has_tail = ctx.line_has_tail
  local section_style_for_line = ctx.section_style_for_line
  local diff_view = setmetatable({}, {
    __index = function(_, key)
      local view = ctx.diff_view and ctx.diff_view() or nil
      return view and view[key] or nil
    end,
  })
  local transcript_ns = ctx.transcript_ns
  local ACP_PIN_ICON = ctx.acp_pin_icon
  local DECORATE_PREFETCH_MARGIN = ctx.decorate_prefetch_margin
  local DECORATE_SYNC_LINE_LIMIT = ctx.decorate_sync_line_limit
  local DECORATE_CHUNK_SIZE = ctx.decorate_chunk_size
  local ensure_highlights = ctx.ensure_highlights
  local INCREMENTAL_NORMALIZE_LOOKBACK = 256

  local transcript_source_lines
  local normalize_header_lines

  local function tail_prefix(line)
    return (line:gsub("[%s─]+$", ""))
  end

  local function fancy_header_line(line)
    local heading = section_heading_for_line(line)
    local replacement = heading and FANCY_SECTION_LABELS[heading] or nil
    if not replacement or line:find(replacement, 1, true) then
      return line
    end
    return replace_heading_token(line, heading, replacement)
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

  local function line_diff_range(left, right)
    left = type(left) == "table" and left or {}
    right = type(right) == "table" and right or {}

    local max_len = math.max(#left, #right)
    local first_diff = nil
    for idx = 1, max_len do
      if left[idx] ~= right[idx] then
        first_diff = idx
        break
      end
    end
    if not first_diff then
      return nil, nil, nil
    end

    local left_tail = #left
    local right_tail = #right
    while left_tail >= first_diff and right_tail >= first_diff and left[left_tail] == right[right_tail] do
      left_tail = left_tail - 1
      right_tail = right_tail - 1
    end

    return first_diff, left_tail, right_tail
  end

  transcript_source_lines = function(bufnr, start_idx, end_idx)
    local raw = layout_entry(bufnr).transcript_source_lines
    if type(raw) ~= "table" then
      return vim.api.nvim_buf_get_lines(bufnr, start_idx, end_idx, false)
    end

    local start_row = math.max(0, tonumber(start_idx) or 0)
    local stop_row = end_idx == -1 and #raw or math.max(start_row, tonumber(end_idx) or #raw)
    stop_row = math.min(#raw, stop_row)

    local lines = {}
    for idx = start_row + 1, stop_row do
      lines[#lines + 1] = raw[idx]
    end
    return lines
  end

  local function incremental_normalize_start(bufnr, start_idx)
    start_idx = math.max(0, tonumber(start_idx) or 0)
    if start_idx <= 0 then
      return 0
    end

    local scan_start = math.max(0, start_idx - INCREMENTAL_NORMALIZE_LOOKBACK)
    local lines = vim.api.nvim_buf_get_lines(bufnr, scan_start, start_idx + 1, false)
    for idx = #lines - 1, 1, -1 do
      local line = lines[idx] or ""
      if section_heading_for_line(line) or line:match("^%s*```") then
        return scan_start + idx - 1
      end
    end
    return scan_start
  end

  local function normalize_transcript_display(bufnr, start_idx)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return nil
    end

    local transcript_stop = transcript_line_count(bufnr)
    if transcript_stop <= 0 then
      return nil
    end

    local normalize_start = start_idx == nil and 0 or math.min(transcript_stop, math.max(0, math.floor(start_idx)))
    if normalize_start > 0 then
      normalize_start = incremental_normalize_start(bufnr, normalize_start)
    end

    local normalized = transcript_source_lines(bufnr, normalize_start, transcript_stop)
    normalized = select(1, normalize_header_lines(bufnr, normalized))
    if diff_view and type(diff_view.normalize_diff_display_lines) == "function" then
      normalized = select(1, diff_view.normalize_diff_display_lines(bufnr, normalized, header_target_width(bufnr)))
    end

    local current = vim.api.nvim_buf_get_lines(bufnr, normalize_start, transcript_stop, false)
    local first_diff, current_last, normalized_last = line_diff_range(current, normalized)
    if not first_diff then
      return nil
    end

    replace_buffer_lines(
      bufnr,
      normalize_start + first_diff - 1,
      normalize_start + current_last,
      vim.list_slice(normalized, first_diff, normalized_last)
    )
    return normalize_start + first_diff - 1
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

    local ok, info = pcall(vim.fn.getwininfo, win)
    local bounds = ok and type(info) == "table" and info[1] or nil
    if type(bounds) ~= "table" then
      return 0, math.min(transcript_stop, DECORATE_CHUNK_SIZE)
    end

    local top = math.max(1, tonumber(bounds.topline) or 1)
    local bottom = math.max(top, tonumber(bounds.botline) or top)
    local range_start = math.max(0, top - 1 - DECORATE_PREFETCH_MARGIN)
    local range_stop = math.min(transcript_stop, bottom + DECORATE_PREFETCH_MARGIN)
    return range_start, math.max(range_start, range_stop)
  end

  normalize_header_lines = function(bufnr, lines)
    local width = header_target_width(bufnr)
    local fancy = fancy_mode_enabled(bufnr)
    if (not width or width <= 0) and not fancy then
      return lines, false
    end

    local changed = false
    local normalized = nil
    for idx, line in ipairs(lines) do
      local rebuilt = line
      if fancy and (rebuilt:match("^─ ") or rebuilt:match("^╭─ ")) then
        rebuilt = fancy_header_line(rebuilt)
      end
      if width and width > 0 and rebuilt:match("^─ ") and line_has_tail(rebuilt) then
        local prefix = tail_prefix(rebuilt)
        local prefix_width = strdisplaywidth(prefix)
        local tail_len = math.max(8, width - prefix_width - 1)
        rebuilt = prefix .. " " .. string.rep("─", tail_len)
      end
      if rebuilt ~= line then
        normalized = normalized or vim.deepcopy(lines)
        normalized[idx] = rebuilt
        changed = true
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
    local entry = layout_entry(bufnr)
    local display_meta = entry.transcript_display_meta or {}
    local heading_rows = type(display_meta.heading_rows) == "table" and display_meta.heading_rows or {}
    local pinned_rows = type(display_meta.pinned_rows) == "table" and display_meta.pinned_rows or nil
    if type(pinned_rows) ~= "table" then
      pinned_rows = pinned_section_rows(bufnr, vim.api.nvim_buf_get_lines(bufnr, 0, transcript_stop, false))
      display_meta.pinned_rows = pinned_rows
      entry.transcript_display_meta = display_meta
    end
    for idx, line in ipairs(lines) do
      local row = range_start + idx - 1
      local header_hl = nil
      if line:match("^─ ") or line:match("^╭─ ") then
        header_hl = section_style_for_line(line)
      else
        local card_heading = heading_rows[row + 1]
        if card_heading == "title" then
          header_hl = "LazyAgentACPCardTitle"
        elseif card_heading == "field" then
          header_hl = "LazyAgentACPCardField"
        end
      end
      if header_hl then
        -- Prefer using vim.highlight.range for a full-line highlight region. Fall back to
        -- extmark or nvim_buf_add_highlight if not available.
        local ok = pcall(function()
          local start_pos = { row, 0 }
          local end_pos = { row, #line }
          vim.highlight.range(bufnr, transcript_ns, header_hl, start_pos, end_pos)
        end)
        if not ok then
          pcall(function()
            vim.api.nvim_buf_set_extmark(bufnr, transcript_ns, row, 0, { hl_group = header_hl, hl_eol = true })
          end)
        end
      end
      if pinned_rows[row + 1] then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, transcript_ns, row, 0, {
          virt_text = { { " " .. ACP_PIN_ICON, "LazyAgentACPPinIcon" } },
          virt_text_pos = "right_align",
          priority = 250,
        })
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

    normalize_transcript_display(bufnr)

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

  return {
    header_target_width = header_target_width,
    overlay_target_width = overlay_target_width,
    transcript_source_lines = transcript_source_lines,
    normalize_transcript_display = normalize_transcript_display,
    normalize_header_lines = normalize_header_lines,
    decorate_transcript_range = decorate_transcript_range,
    decorate_buffer = decorate_buffer,
  }
end

return M
