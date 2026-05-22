local M = {}

function M.new(ctx)
  local pane_opts_for_bufnr = ctx.pane_opts_for_bufnr
  local collect_transcript_sections = ctx.collect_transcript_sections
  local runtime_conversation_timeline = ctx.runtime_conversation_timeline
  local layout_entry = ctx.layout_entry
  local trailing_markdown_table_context = ctx.trailing_markdown_table_context
  local balance_unclosed_markdown_fences = ctx.balance_unclosed_markdown_fences
  local transform_markdown_tables = ctx.transform_markdown_tables
  local transcript_table_layout = ctx.transcript_table_layout
  local fancy_mode_enabled = ctx.fancy_mode_enabled
  local transcript_max_lines = ctx.transcript_max_lines
  local TRANSCRIPT_TRUNCATED_MARKER = ctx.transcript_truncated_marker

  local pinned_section_rows
  local read_transcript_lines

  local function transcript_compaction_config(bufnr)
    local opts = pane_opts_for_bufnr(bufnr)
    local cfg = type(opts and opts.transcript_compaction) == "table" and opts.transcript_compaction or {}
    local min_sections = tonumber(cfg.min_sections) or 48
    local keep_recent_sections = tonumber(cfg.keep_recent_sections) or 24
    local summary_items = tonumber(cfg.summary_items) or 6
    return {
      enabled = cfg.enabled == true,
      min_sections = math.max(2, math.floor(min_sections)),
      keep_recent_sections = math.max(1, math.floor(keep_recent_sections)),
      summary_items = math.max(1, math.floor(summary_items)),
    }
  end

  local function section_chunk_stop(sections, idx, total_lines)
    if idx < #sections then
      return math.max(sections[idx].end_row, sections[idx + 1].start_row - 1)
    end
    return math.max(sections[idx].end_row, total_lines)
  end

  local function append_line_range(target, source, start_row, stop_row)
    for row = start_row, stop_row do
      target[#target + 1] = source[row] or ""
    end
  end

  local function summarize_compacted_text(text, limit)
    text = tostring(text or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    limit = tonumber(limit) or 120
    if text == "" then
      return ""
    end
    if #text <= limit then
      return text
    end
    return text:sub(1, math.max(1, limit - 1)) .. "…"
  end

  local function section_summary_text(lines, section)
    if type(section) ~= "table" then
      return ""
    end
    for row = section.start_row + 1, section.end_row do
      local text = summarize_compacted_text((lines[row] or ""):gsub("^%s+", ""), 120)
      if text ~= "" then
        return text
      end
    end
    return ""
  end

  local function transcript_items_for_sections(bufnr, sections)
    local items = {}
    local timeline = runtime_conversation_timeline(bufnr)
    local offset = math.max(#timeline - #sections, 0)
    for idx = 1, #sections do
      items[idx] = timeline[offset + idx]
    end
    return items
  end

  pinned_section_rows = function(bufnr, lines)
    lines = type(lines) == "table" and lines or {}
    local sections = collect_transcript_sections(lines)
    if #sections == 0 then
      return {}
    end

    local entry = layout_entry(bufnr)
    local items = type(entry.transcript_section_items) == "table" and entry.transcript_section_items or nil
    if type(items) ~= "table" or #items ~= #sections then
      items = transcript_items_for_sections(bufnr, sections)
    end

    local pinned_rows = {}
    for idx, section in ipairs(sections) do
      if type(items[idx]) == "table" and items[idx].pinned == true then
        pinned_rows[section.start_row] = true
      end
    end

    return pinned_rows
  end

  local function with_transcript_display_meta(meta, sections, compacted, lines)
    meta = type(meta) == "table" and meta or {}
    meta.raw_section_count = #(sections or {})
    meta.compacted = compacted == true
    meta.table_tail_state = trailing_markdown_table_context(lines).state
    return meta
  end

  local function compacted_block_body(bufnr, lines, sections, items, cfg)
    local counts = {}
    local ordered_counts = {}
    local highlights = {}
    local seen_highlights = {}
    local fancy = fancy_mode_enabled(bufnr)

    for idx, section in ipairs(sections) do
      local item = items[idx]
      local label = (item and item.heading) or section.heading or "Section"
      if counts[label] == nil then
        ordered_counts[#ordered_counts + 1] = label
        counts[label] = 0
      end
      counts[label] = counts[label] + 1

      local summary = summarize_compacted_text(item and item.summary or section_summary_text(lines, section), 120)
      if summary ~= "" and not seen_highlights[summary] and #highlights < cfg.summary_items then
        seen_highlights[summary] = true
        highlights[#highlights + 1] = summary
      end
    end

    local body = {
      fancy
          and string.format("🎉✨ Earlier transcript compacted (%d sections). ✨🎉", #sections)
        or string.format("Earlier transcript compacted (%d sections).", #sections),
    }

    if #ordered_counts > 0 then
      local parts = {}
      for _, label in ipairs(ordered_counts) do
        parts[#parts + 1] = string.format("%s x%d", label, counts[label])
      end
      body[#body + 1] = (fancy and "🎈 " or "- ") .. table.concat(parts, ", ")
    end

    for _, highlight in ipairs(highlights) do
      body[#body + 1] = (fancy and "🌟 " or "- ") .. highlight
    end

    return body
  end

  local function compacted_section_lines(bufnr, lines, sections, items, cfg)
    local body = compacted_block_body(bufnr, lines, sections, items, cfg)
    local rendered = { "─ System" }
    for _, line in ipairs(body) do
      rendered[#rendered + 1] = " " .. line
    end
    rendered[#rendered + 1] = ""
    local start_row = sections[1] and sections[1].start_row or 1
    local stop_row = sections[#sections] and section_chunk_stop(sections, #sections, #lines) or start_row
    return rendered, {
      kind = "compacted",
      heading = "System",
      title = "Compacted earlier transcript",
      summary = string.format("%d sections compacted", #sections),
      compacted_section_count = #sections,
      compacted_relative_start_row = start_row,
      compacted_relative_stop_row = stop_row,
      compacted_max_lines = transcript_max_lines(bufnr),
    }
  end

  local function compact_transcript_lines(bufnr, raw_lines)
    raw_lines = type(raw_lines) == "table" and raw_lines or {}
    local cfg = transcript_compaction_config(bufnr)
    local sections = collect_transcript_sections(raw_lines)
    local items = transcript_items_for_sections(bufnr, sections)
    if not cfg.enabled or #sections < cfg.min_sections then
      local balanced_lines = balance_unclosed_markdown_fences(raw_lines)
      local transformed, _, meta = transform_markdown_tables(balanced_lines, transcript_table_layout(bufnr))
      return transformed, items, with_transcript_display_meta(meta, sections, false, balanced_lines)
    end

    local keep_recent = math.min(#sections, cfg.keep_recent_sections)
    local compact_limit = #sections - keep_recent
    if compact_limit < 2 then
      local balanced_lines = balance_unclosed_markdown_fences(raw_lines)
      local transformed, _, meta = transform_markdown_tables(balanced_lines, transcript_table_layout(bufnr))
      return transformed, items, with_transcript_display_meta(meta, sections, false, balanced_lines)
    end

    local out_lines = {}
    local out_items = {}
    if raw_lines[1] == TRANSCRIPT_TRUNCATED_MARKER then
      out_lines[#out_lines + 1] = TRANSCRIPT_TRUNCATED_MARKER
    end

    local idx = 1
    while idx <= #sections do
      local item = items[idx]
      if idx <= compact_limit and not (item and item.pinned == true) then
        local group_start = idx
        while idx <= compact_limit and not (items[idx] and items[idx].pinned == true) do
          idx = idx + 1
        end
        local group_end = idx - 1
        if group_end - group_start + 1 >= 2 then
          local group_sections = vim.list_slice(sections, group_start, group_end)
          local group_items = vim.list_slice(items, group_start, group_end)
          local rendered, synthetic_item = compacted_section_lines(bufnr, raw_lines, group_sections, group_items, cfg)
          vim.list_extend(out_lines, rendered)
          out_items[#out_items + 1] = synthetic_item
        else
          append_line_range(out_lines, raw_lines, sections[group_start].start_row, section_chunk_stop(sections, group_start, #raw_lines))
          out_items[#out_items + 1] = items[group_start]
        end
      else
        append_line_range(out_lines, raw_lines, sections[idx].start_row, section_chunk_stop(sections, idx, #raw_lines))
        out_items[#out_items + 1] = item
        idx = idx + 1
      end
    end

    local balanced_out_lines = balance_unclosed_markdown_fences(out_lines)
    local transformed, _, meta = transform_markdown_tables(balanced_out_lines, transcript_table_layout(bufnr))
    return transformed, out_items, with_transcript_display_meta(meta, sections, true, balanced_out_lines)
  end

  read_transcript_lines = function(path, max_lines)
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

  return {
    transcript_compaction_config = transcript_compaction_config,
    pinned_section_rows = pinned_section_rows,
    compact_transcript_lines = compact_transcript_lines,
    read_transcript_lines = read_transcript_lines,
  }
end

return M
