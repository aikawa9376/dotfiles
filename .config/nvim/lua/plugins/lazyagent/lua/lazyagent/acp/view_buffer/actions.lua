local M = {}

function M.new(ctx)
  local runtime_tool_timeline = ctx.runtime_tool_timeline
  local visible_conversation_context = ctx.visible_conversation_context
  local section_text = ctx.section_text
  local section_body_text = ctx.section_body_text
  local normalize_popup_text = ctx.normalize_popup_text
  local text_looks_like_transcript = ctx.text_looks_like_transcript
  local copy_to_clipboard = ctx.copy_to_clipboard
  local show_outline_picker = ctx.show_outline_picker
  local toggle_current_pin = ctx.toggle_current_pin
  local backend_for_agent = ctx.backend_for_agent
  local agent_name_for_bufnr = ctx.agent_name_for_bufnr
  local pane_id_for_bufnr = ctx.pane_id_for_bufnr
  local cleanup_markdown_rendering = ctx.cleanup_markdown_rendering
  local read_transcript_lines = ctx.read_transcript_lines
  local fancy_mode_enabled = ctx.fancy_mode_enabled
  local dedicated_transcript_windows = ctx.dedicated_transcript_windows
  local ACP_TRANSCRIPT_FILETYPE = ctx.acp_transcript_filetype
  local layout_entry = ctx.layout_entry
  local strdisplaywidth = ctx.strdisplaywidth
  local FANCY_POPUP_MARKDOWN_TITLES = ctx.fancy_popup_markdown_titles
  local FANCY_POPUP_SECTION_HEADINGS = ctx.fancy_popup_section_headings
  local diff_view = setmetatable({}, {
    __index = function(_, key)
      local view = ctx.diff_view and ctx.diff_view() or nil
      return view and view[key] or nil
    end,
  })
  local metadata_popup_win = nil
  local metadata_popup_source_buf = nil

  local function tool_entry_for_item(bufnr, item)
    if type(item) ~= "table" or not item.toolCallId or item.toolCallId == "" then
      return nil
    end

    for _, entry in ipairs(runtime_tool_timeline(bufnr)) do
      if type(entry) == "table" and entry.toolCallId == item.toolCallId then
        return entry
      end
    end

    local backend = backend_for_agent(agent_name_for_bufnr(bufnr))
    if backend and type(backend.get_tool_timeline_entry) == "function" then
      return backend.get_tool_timeline_entry(pane_id_for_bufnr(bufnr), item.toolCallId)
    end

    return nil
  end

  local function show_outline_picker(bufnr, pinned_only)
    local context = visible_conversation_context(bufnr)
    local win = vim.api.nvim_get_current_win()
    local entries = {}

    for idx, section in ipairs(context and context.sections or {}) do
      local item = context.items[idx]
      if not pinned_only or (item and item.pinned == true) then
        entries[#entries + 1] = {
          section = section,
          item = item,
        }
      end
    end

    if #entries == 0 then
      vim.notify(pinned_only and "No pinned blocks" or "No transcript blocks", vim.log.levels.INFO)
      return
    end

    vim.ui.select(entries, {
      prompt = pinned_only and "Pinned ACP blocks:" or "ACP outline:",
      format_item = function(entry)
        local item = entry.item or {}
        local pin = item.pinned and "[pin] " or ""
        local label = item.title or item.heading or entry.section.heading or "Block"
        local summary = item.summary and item.summary ~= "" and (" - " .. item.summary) or ""
        local status = item.status and item.status ~= "" and (" [" .. item.status .. "]") or ""
        return string.format("%s%s%s%s", pin, label, status, summary)
      end,
    }, function(choice)
      if choice and vim.api.nvim_win_is_valid(win) then
        jump_window_to_row(win, choice.section.start_row)
      end
    end)
  end

  local function toggle_current_pin(bufnr)
    local context = visible_conversation_context(bufnr)
    local item = context and context.item or nil
    if not item or not item.id or item.id == "" then
      vim.notify("No pinnable ACP block under cursor", vim.log.levels.INFO)
      return
    end

    local backend = backend_for_agent(agent_name_for_bufnr(bufnr))
    local pinned = nil
    if backend and type(backend.toggle_conversation_pin) == "function" then
      pinned = backend.toggle_conversation_pin(pane_id_for_bufnr(bufnr), item.id)
    end
    if pinned == nil then
      pinned = not item.pinned
      item.pinned = pinned
    end

    vim.notify(pinned and "Pinned current block" or "Unpinned current block", vim.log.levels.INFO)
    local session = session_for_agent(agent_name_for_bufnr(bufnr))
    local transcript_path = session and session.transcript_path or nil
    if not transcript_path or transcript_path == "" then
      local ok, value = pcall(vim.api.nvim_buf_get_var, bufnr, "lazyagent_acp_transcript_path")
      transcript_path = ok and value or nil
    end
    pcall(
      refresh_buffer_from_path,
      bufnr,
      transcript_path,
      { force = true }
    )
  end

  local function copy_current_block(bufnr)
    local context = visible_conversation_context(bufnr)
    local text = section_text(context and context.lines or {}, context and context.section or nil)
    copy_to_clipboard(text, "Copied current block")
  end

  local function copy_current_tool_output(bufnr)
    local context = visible_conversation_context(bufnr)
    local entry = tool_entry_for_item(bufnr, context and context.item or nil)
    if not entry then
      vim.notify("No tool output for this block", vim.log.levels.INFO)
      return
    end

    local parts = {}
    if entry.rendered_content and entry.rendered_content ~= "" then
      parts[#parts + 1] = entry.rendered_content
    end
    if entry.rendered_raw_output and entry.rendered_raw_output ~= "" then
      if #parts > 0 then
        parts[#parts + 1] = ""
      end
      parts[#parts + 1] = "Raw output:"
      parts[#parts + 1] = entry.rendered_raw_output
    end

    if #parts == 0 then
      local message = entry.compacted == true
          and "Tool output was compacted; open the full/raw ACP transcript for details"
        or "No tool output for this block"
      vim.notify(message, vim.log.levels.INFO)
      return
    end

    copy_to_clipboard(table.concat(parts, "\n"), "Copied tool output")
  end

    local function open_current_tool_output(bufnr)
      local context = visible_conversation_context(bufnr)
      local item = context and context.item or nil
      if not item or not item.toolCallId or item.toolCallId == "" then
        vim.notify("No tool output for this block", vim.log.levels.INFO)
        return
      end

      local backend = backend_for_agent(agent_name_for_bufnr(bufnr))
      if backend and type(backend.show_tool_timeline_entry) == "function" then
        if backend.show_tool_timeline_entry(pane_id_for_bufnr(bufnr), item.toolCallId) then
          return
        end
      end

      vim.notify("Tool output viewer is unavailable for this block", vim.log.levels.WARN)
    end

    local function close_metadata_popup()
      local popup_buf = nil
      if metadata_popup_win and vim.api.nvim_win_is_valid(metadata_popup_win) then
        popup_buf = vim.api.nvim_win_get_buf(metadata_popup_win)
      end
      if popup_buf and vim.api.nvim_buf_is_valid(popup_buf) then
        cleanup_markdown_rendering(popup_buf)
      end
      if metadata_popup_win and vim.api.nvim_win_is_valid(metadata_popup_win) then
        pcall(vim.api.nvim_win_close, metadata_popup_win, true)
      end
      metadata_popup_win = nil
      metadata_popup_source_buf = nil
    end

    local function metadata_popup_is_open()
      return metadata_popup_win ~= nil and vim.api.nvim_win_is_valid(metadata_popup_win)
    end

    local function install_source_popup_close_keymap(bufnr)
      if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      vim.keymap.set("n", "q", function()
        if metadata_popup_is_open() and metadata_popup_source_buf == bufnr then
          close_metadata_popup()
          return "<Ignore>"
        end
        return "q"
      end, {
        buffer = bufnr,
        expr = true,
        noremap = true,
        nowait = true,
        silent = true,
        replace_keycodes = true,
        desc = "LazyAgentACP: close metadata popup",
      })
    end

    local function normalize_popup_lines(lines)
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
      if #normalized == 0 then
        normalized[1] = "(no metadata)"
      end
      return normalized
    end

    local function append_scalar_field(lines, label, value)
      if value == nil then
        return
      end
      local text = tostring(value)
      if text == "" then
        return
      end
      lines[#lines + 1] = string.format("%s: %s", label, text)
    end

    local function append_list_field(lines, label, values)
      if type(values) ~= "table" or vim.tbl_isempty(values) then
        return
      end
      lines[#lines + 1] = label .. ":"
      for _, value in ipairs(values) do
        local text = tostring(value or "")
        if text ~= "" then
          lines[#lines + 1] = "- " .. text
        end
      end
    end

    local function append_text_section(lines, heading, text)
      text = tostring(text or "")
      if text == "" then
        return
      end
      lines[#lines + 1] = ""
      lines[#lines + 1] = heading .. ":"
      vim.list_extend(lines, vim.split(text, "\n", { plain = true }))
    end

    local function popup_markdown_title(bufnr, kind, fallback)
      if fancy_mode_enabled(bufnr) then
        return FANCY_POPUP_MARKDOWN_TITLES[kind] or fallback
      end
      return fallback
    end

    local function popup_window_title(bufnr, title, emoji)
      if not fancy_mode_enabled(bufnr) then
        return title
      end
      return string.format("%s %s %s", emoji, title, emoji)
    end

    local function popup_section_heading(bufnr, heading)
      if fancy_mode_enabled(bufnr) then
        return FANCY_POPUP_SECTION_HEADINGS[heading] or heading
      end
      return heading
    end

    local function compacted_transcript_preview_lines(bufnr, item)
      if type(item) ~= "table" or item.kind ~= "compacted" then
        return {}
      end

      local start_row = tonumber(item.compacted_relative_start_row)
      local stop_row = tonumber(item.compacted_relative_stop_row)
      if not start_row or not stop_row then
        return {}
      end

      local ok, transcript_path = pcall(vim.api.nvim_buf_get_var, bufnr, "lazyagent_acp_transcript_path")
      if not ok or type(transcript_path) ~= "string" or transcript_path == "" then
        return {}
      end

      local slice_lines = read_transcript_lines(transcript_path, item.compacted_max_lines)
      if type(slice_lines) ~= "table" or #slice_lines == 0 then
        return {}
      end

      start_row = math.max(1, math.floor(start_row))
      stop_row = math.max(start_row, math.floor(stop_row))
      if start_row > #slice_lines then
        return {}
      end
      stop_row = math.min(stop_row, #slice_lines)

      local preview = vim.list_slice(slice_lines, start_row, stop_row)
      while #preview > 0 and preview[#preview] == "" do
        table.remove(preview)
      end
      return preview
    end

    local function popup_source_window(bufnr)
      if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
        return nil
      end

      local source_win = vim.api.nvim_get_current_win()
      if not source_win or not vim.api.nvim_win_is_valid(source_win) then
        return nil
      end
      if vim.api.nvim_win_get_buf(source_win) ~= bufnr then
        return nil
      end
      local ok_cfg, cfg = pcall(vim.api.nvim_win_get_config, source_win)
      if not ok_cfg or not cfg or cfg.relative ~= "" then
        return nil
      end
      local tracked = dedicated_transcript_windows[tostring(source_win)]
      if not tracked or tracked.bufnr ~= bufnr then
        return nil
      end

      local ok, is_transcript = pcall(function()
        return vim.b[bufnr].lazyagent_acp_transcript
      end)
      if not ok or is_transcript ~= true then
        return nil
      end
      if vim.bo[bufnr].filetype ~= ACP_TRANSCRIPT_FILETYPE then
        return nil
      end

      return source_win
    end

    local function build_block_metadata_lines(bufnr, context, item)
      local section = context and context.section or {}
      local body = section_body_text(context and context.lines or {}, section)
      local item_body = type(item) == "table" and tostring(item.body or "") or ""
      if body == "" and item_body ~= "" and not text_looks_like_transcript(item_body) then
        body = item_body
      end

      local metadata = {
        id = item and item.id or nil,
        seq = item and item.seq or nil,
        kind = item and item.kind or nil,
        heading = item and item.heading or section.heading,
        title = item and item.title or section.heading,
        status = item and item.status or nil,
        path = item and item.path or nil,
        toolCallId = item and item.toolCallId or nil,
        pinned = item and item.pinned == true or false,
        summary = item and item.summary or nil,
        transcript_range = section.start_row and string.format("%d-%d", section.start_row, section.end_row or section.start_row) or nil,
      }

      local lines = { popup_markdown_title(bufnr, "block", "# ACP Block Metadata"), "" }
      append_scalar_field(lines, "ID", metadata.id)
      append_scalar_field(lines, "Seq", metadata.seq)
      append_scalar_field(lines, "Title", metadata.title)
      append_scalar_field(lines, "Heading", metadata.heading)
      append_scalar_field(lines, "Kind", metadata.kind)
      append_scalar_field(lines, "Status", metadata.status)
      append_scalar_field(lines, "Path", metadata.path)
      append_scalar_field(lines, "Tool Call", metadata.toolCallId)
      append_scalar_field(lines, "Pinned", metadata.pinned)
      append_scalar_field(lines, "Transcript lines", metadata.transcript_range)
      append_text_section(lines, popup_section_heading(bufnr, "Summary"), metadata.summary)
      append_text_section(lines, popup_section_heading(bufnr, "Content"), body)
      return lines
    end

    local function preferred_tool_popup_sections(context, item, entry)
      local section = context and context.section or {}
      local transcript_body = section_body_text(context and context.lines or {}, section)
      local item_body = type(item) == "table" and tostring(item.body or "") or ""
      local content = tostring(entry and entry.rendered_content or "")
      local raw_output = tostring(entry and entry.rendered_raw_output or "")

      if text_looks_like_transcript(content) then
        content = ""
      end
      if text_looks_like_transcript(raw_output) then
        raw_output = ""
      end
      if content == "" and item_body ~= "" and not text_looks_like_transcript(item_body) then
        content = item_body
      end
      if content == "" then
        content = transcript_body
      end

      if normalize_popup_text(raw_output) == normalize_popup_text(content) then
        raw_output = ""
      end
      if normalize_popup_text(transcript_body) == normalize_popup_text(content) then
        transcript_body = ""
      end

      return content, raw_output, transcript_body
    end

    local function build_tool_metadata_lines(bufnr, context, item, entry)
      local section = context and context.section or {}
      local paths = type(entry and entry.paths) == "table" and vim.deepcopy(entry.paths) or {}
      if #paths == 0 and item and item.path and item.path ~= "" then
        paths = { item.path }
      end
      local content, raw_output, transcript_body = preferred_tool_popup_sections(context, item, entry)
      local metadata = {
        toolCallId = entry and entry.toolCallId or item and item.toolCallId or nil,
        title = entry and entry.title or item and item.title or nil,
        heading = entry and entry.heading or item and item.heading or section.heading,
        status = entry and entry.status or item and item.status or nil,
        kind = entry and entry.kind or item and item.kind or "tool",
        pinned = (entry and entry.pinned == true) or (item and item.pinned == true) or false,
        summary = entry and entry.summary or item and item.summary or nil,
        paths = paths,
        transcript_range = section.start_row and string.format("%d-%d", section.start_row, section.end_row or section.start_row) or nil,
        conversation_item_id = item and item.id or nil,
      }

      local lines = { popup_markdown_title(bufnr, "tool", "# ACP Tool Metadata"), "" }
      append_scalar_field(lines, "Tool Call", metadata.toolCallId)
      append_scalar_field(lines, "Title", metadata.title)
      append_scalar_field(lines, "Heading", metadata.heading)
      append_scalar_field(lines, "Kind", metadata.kind)
      append_scalar_field(lines, "Status", metadata.status)
      append_scalar_field(lines, "Pinned", metadata.pinned)
      append_scalar_field(lines, "Transcript lines", metadata.transcript_range)
      append_scalar_field(lines, "Conversation item", metadata.conversation_item_id)
      append_list_field(lines, "Paths", metadata.paths)
      append_text_section(lines, popup_section_heading(bufnr, "Summary"), metadata.summary)
      append_text_section(lines, popup_section_heading(bufnr, "Content"), content)
      append_text_section(lines, popup_section_heading(bufnr, "Raw output"), raw_output)
      append_text_section(lines, popup_section_heading(bufnr, "Transcript"), transcript_body)
      return lines
    end

    local function build_compacted_metadata_lines(bufnr, context, item)
      local section = context and context.section or {}
      local preview_lines = compacted_transcript_preview_lines(bufnr, item)
      local lines = { popup_markdown_title(bufnr, "compacted", "# ACP Compacted Transcript"), "" }
      append_scalar_field(lines, "Title", item and item.title or nil)
      append_scalar_field(lines, "Compacted sections", item and item.compacted_section_count or nil)
      append_scalar_field(
        lines,
        "Displayed lines",
        section.start_row and string.format("%d-%d", section.start_row, section.end_row or section.start_row) or nil
      )
      append_text_section(lines, popup_section_heading(bufnr, "Summary"), item and item.summary or nil)
      append_text_section(
        lines,
        popup_section_heading(bufnr, "Expanded transcript"),
        table.concat(preview_lines, "\n")
      )
      if #preview_lines == 0 then
        append_text_section(
          lines,
          popup_section_heading(bufnr, "Expanded transcript"),
          "(source transcript unavailable)"
        )
      end
      return lines
    end

    local function metadata_popup_spec(bufnr, win)
      local context = current_display_conversation_context(bufnr, win)
      if not context or not context.section then
        return nil
      end

      local entry = layout_entry(bufnr)
      local indexed_item = type(entry.transcript_section_items) == "table" and entry.transcript_section_items[context.index] or nil
      local item = indexed_item or context.item or {}
      if item.kind == "compacted" then
        local title = popup_window_title(bufnr, tostring(item.title or "Compacted transcript"), "🎉📦")
        return {
          title = " " .. title .. " ",
          lines = build_compacted_metadata_lines(bufnr, context, item),
        }
      end

      local tool_entry = tool_entry_for_item(bufnr, item)
      local section_heading = context.section and context.section.heading or nil
      local is_tool_section = section_heading == "Tool" or section_heading == "Edited"
      if tool_entry or is_tool_section or item.kind == "tool" or (item.toolCallId and item.toolCallId ~= "") then
        local title = tool_entry and (tool_entry.title or tool_entry.toolCallId)
          or item.title
          or item.toolCallId
          or section_heading
          or "ACP Tool Metadata"
        title = popup_window_title(bufnr, tostring(title), "🧰✨")
        return {
          title = " " .. tostring(title) .. " ",
          lines = build_tool_metadata_lines(bufnr, context, item, tool_entry),
        }
      end

      local title = item.title or context.section.heading or "ACP Block Metadata"
      title = popup_window_title(bufnr, tostring(title), "🎀🌈")
      return {
        title = " " .. tostring(title) .. " ",
        lines = build_block_metadata_lines(bufnr, context, item),
      }
    end

    local function cursor_screen_position(win)
      local cursor = vim.api.nvim_win_get_cursor(win)
      local ok_pos, pos = pcall(vim.fn.screenpos, win, cursor[1], cursor[2] + 1)
      if ok_pos and type(pos) == "table" and tonumber(pos.row) and tonumber(pos.col) then
        local row = math.max(0, (tonumber(pos.row) or 1) - 1)
        local col = math.max(0, (tonumber(pos.endcol) or tonumber(pos.col) or 1) - 1)
        return row, col
      end

      local ok_win, win_pos = pcall(vim.api.nvim_win_get_position, win)
      if ok_win and type(win_pos) == "table" and win_pos[1] ~= nil and win_pos[2] ~= nil then
        return math.max(0, win_pos[1] + math.max(0, (vim.fn.winline() or 1) - 1)),
          math.max(0, win_pos[2] + math.max(0, (vim.fn.wincol() or 1) - 1))
      end

      return 0, 0
    end

    local function popup_geometry(win, lines)
      local ui = vim.api.nvim_list_uis()[1] or {}
      local editor_height = math.max(1, tonumber(ui.height) or vim.o.lines or 24)
      local editor_width = math.max(1, tonumber(ui.width) or vim.o.columns or 80)
      local max_width = math.max(1, editor_width - 2)
      local max_height = math.max(1, editor_height - 2)
      local width_limit = math.min(max_width, math.max(24, math.min(72, math.floor(editor_width * 0.42))))
      local height_limit = math.min(max_height, math.max(6, math.min(16, math.floor(editor_height * 0.45))))
      local max_line_width = 0
      for _, line in ipairs(lines) do
        max_line_width = math.max(max_line_width, strdisplaywidth(line))
      end

      local preferred_width = math.max(28, math.min(max_line_width + 2, 60))
      local preferred_height = math.max(6, math.min(#lines, 14))
      local width = math.max(1, math.min(width_limit, preferred_width))
      local height = math.max(1, math.min(height_limit, preferred_height))
      local cursor_row, cursor_col = cursor_screen_position(win)
      local right_space = math.max(0, editor_width - cursor_col - 2)
      local left_space = math.max(0, cursor_col - 1)

      local col = cursor_col + 2
      if right_space < width and left_space >= width then
        col = cursor_col - width - 1
      else
        col = math.min(col, math.max(0, editor_width - width))
      end
      col = math.max(0, math.min(col, math.max(0, editor_width - width)))

      local row
      if cursor_row >= height + 1 then
        row = cursor_row - height
      else
        row = cursor_row - math.min(2, height - 1)
      end
      row = math.max(0, math.min(row, math.max(0, editor_height - height)))

      return width, height, row, col
    end

    local function show_metadata_popup(bufnr)
      local source_win = popup_source_window(bufnr)
      if not source_win then
        return
      end

      local spec = metadata_popup_spec(bufnr, source_win)
      if not spec then
        vim.notify("No ACP block under cursor", vim.log.levels.INFO)
        return
      end

      close_metadata_popup()

      local lines = normalize_popup_lines(spec.lines)
      local width, height, row, col = popup_geometry(source_win, lines)
      local popup_buf = vim.api.nvim_create_buf(false, true)
      vim.bo[popup_buf].bufhidden = "wipe"
      vim.bo[popup_buf].swapfile = false
      vim.bo[popup_buf].modifiable = true
      vim.bo[popup_buf].readonly = false
      vim.bo[popup_buf].filetype = "markdown"
      vim.b[popup_buf].lazyagent_acp_metadata_popup = true
      vim.api.nvim_buf_set_lines(popup_buf, 0, -1, false, lines)
      vim.bo[popup_buf].modifiable = false
      vim.bo[popup_buf].readonly = true

      metadata_popup_win = vim.api.nvim_open_win(popup_buf, true, {
        relative = "editor",
        row = row,
        col = col,
        width = width,
        height = height,
        style = "minimal",
        border = "rounded",
        title = spec.title,
        title_pos = "center",
        zindex = 90,
      })
      metadata_popup_source_buf = bufnr
      install_source_popup_close_keymap(bufnr)

      vim.wo[metadata_popup_win].wrap = true
      vim.wo[metadata_popup_win].linebreak = true
      vim.wo[metadata_popup_win].cursorline = false
      vim.wo[metadata_popup_win].number = false
      vim.wo[metadata_popup_win].relativenumber = false
      vim.wo[metadata_popup_win].signcolumn = "no"
      vim.wo[metadata_popup_win].foldcolumn = "0"
      vim.wo[metadata_popup_win].winhighlight = "FloatBorder:LazyAgentACPBorder"

      local function close_and_restore_focus()
        close_metadata_popup()
        if source_win and vim.api.nvim_win_is_valid(source_win) then
          pcall(vim.api.nvim_set_current_win, source_win)
        end
      end

      vim.keymap.set("n", "q", close_and_restore_focus, {
        buffer = popup_buf,
        noremap = true,
        nowait = true,
        silent = true,
        desc = "LazyAgentACP: close metadata popup",
      })
      vim.keymap.set("n", "<Esc>", close_and_restore_focus, {
        buffer = popup_buf,
        noremap = true,
        silent = true,
        desc = "LazyAgentACP: close metadata popup",
      })
    end

    local function preview_current_diff_source(bufnr)
      if not diff_view or type(diff_view.preview_diff_block_under_cursor) ~= "function" then
        vim.notify("Diff preview is unavailable", vim.log.levels.WARN)
        return
      end

      local ok, opened = pcall(diff_view.preview_diff_block_under_cursor, bufnr)
      if not ok then
        vim.notify("LazyAgentACP: failed to preview diff source", vim.log.levels.WARN)
        return
      end
      if not opened then
        vim.notify("No diff block under cursor", vim.log.levels.INFO)
      end
    end

    local function show_action_menu(bufnr)
      local context = visible_conversation_context(bufnr)
      if not context or not context.section then
        vim.notify("No ACP block under cursor", vim.log.levels.INFO)
        return
      end

      local item = context.item or {}
      local backend = backend_for_agent(agent_name_for_bufnr(bufnr))
      local actions = {
        {
          label = "Switch provider",
          action = function()
            require("lazyagent.logic.session").switch_acp_provider(agent_name_for_bufnr(bufnr))
          end,
        },
        {
          label = "Sessions",
          action = function()
            require("lazyagent.logic.session").pick_acp_sessions(agent_name_for_bufnr(bufnr))
          end,
        },
        {
          label = "Outline",
          action = function()
            show_outline_picker(bufnr, false)
          end,
        },
        {
          label = "Pinned",
          action = function()
            show_outline_picker(bufnr, true)
          end,
        },
        {
          label = item.pinned and "Unpin current block" or "Pin current block",
          action = function()
            toggle_current_pin(bufnr)
          end,
        },
        {
          label = "Copy current block",
          action = function()
            copy_current_block(bufnr)
          end,
        },
        {
          label = "Show metadata",
          action = function()
            show_metadata_popup(bufnr)
          end,
        },
      }

      if backend and type(backend.show_tool_timeline) == "function" then
        actions[#actions + 1] = {
          label = "Tool timeline",
          action = function()
            backend.show_tool_timeline(pane_id_for_bufnr(bufnr))
          end,
        }
      end

      if diff_view and type(diff_view.has_diff_block_under_cursor) == "function"
          and diff_view.has_diff_block_under_cursor(bufnr) then
        actions[#actions + 1] = {
          label = "Preview diff source",
          action = function()
            preview_current_diff_source(bufnr)
          end,
        }
      end

      if item.toolCallId and item.toolCallId ~= "" then
        actions[#actions + 1] = {
          label = "Open tool output",
          action = function()
            open_current_tool_output(bufnr)
          end,
        }
        actions[#actions + 1] = {
          label = "Copy tool output",
          action = function()
            copy_current_tool_output(bufnr)
          end,
        }
      end

      vim.ui.select(actions, {
        prompt = "ACP actions:",
        format_item = function(entry)
          return entry.label
        end,
      }, function(choice)
        if choice and type(choice.action) == "function" then
          choice.action()
        end
      end)
  end

  return {
    show_action_menu = show_action_menu,
    show_metadata_popup = show_metadata_popup,
    close_metadata_popup = close_metadata_popup,
  }
end

return M
