local M = {}

local ns = vim.api.nvim_create_namespace("lazyagent_acp_qf_annotations")
local augroup = nil
local path_annotations = {}
local popup_win = nil
local popup_buf = nil

local ICON = " "
local MAX_SECTION_BYTES = 6000
local MAX_COMMENT_LINES = 120

local function setup_highlights()
  vim.api.nvim_set_hl(0, "LazyAgentACPQuickfixAnnotation", {
    default = true,
    link = "DiagnosticInfo",
  })
  vim.api.nvim_set_hl(0, "LazyAgentACPQuickfixAnnotationTitle", {
    default = true,
    link = "Title",
  })
end

local function normalize_path(path)
  local text = tostring(path or "")
  if text == "" then
    return nil
  end

  local ok, normalized = pcall(vim.fn.fnamemodify, text, ":p")
  if not ok or not normalized or normalized == "" then
    normalized = text
  end
  if vim.fs and type(vim.fs.normalize) == "function" then
    normalized = vim.fs.normalize(normalized)
  end
  return normalized
end

local function path_for_item(item)
  if type(item) ~= "table" then
    return nil
  end
  if item.filename and item.filename ~= "" then
    return normalize_path(item.filename)
  end
  local bufnr = tonumber(item.bufnr)
  if bufnr and bufnr > 0 then
    local name = vim.fn.bufname(bufnr)
    if name and name ~= "" then
      return normalize_path(name)
    end
  end
  return nil
end

local function compact_one_line(text, limit)
  local value = tostring(text or "")
  value = value:gsub("\27%[[0-9;]*m", "")
  value = vim.trim(value:gsub("%s+", " "))
  if value == "" then
    return ""
  end
  limit = tonumber(limit) or 160
  if vim.fn.strdisplaywidth(value) > limit then
    value = vim.fn.strcharpart(value, 0, limit - 3) .. "..."
  end
  return value
end

local function truncate_section(text)
  local value = tostring(text or "")
  if value == "" then
    return ""
  end
  if #value <= MAX_SECTION_BYTES then
    return value
  end
  return value:sub(1, MAX_SECTION_BYTES) .. "\n...(truncated)"
end

local function annotation_from_item(item, idx, list_title)
  if type(item) ~= "table" then
    return nil
  end
  local user_data = type(item.user_data) == "table" and item.user_data or nil
  local source = user_data and user_data.lazyagent_acp or nil
  if type(source) ~= "table" then
    return nil
  end

  local filename = path_for_item(item)
  if not filename then
    return nil
  end
  local lnum = math.max(1, tonumber(item.lnum) or tonumber(source.lnum) or 1)
  local col = math.max(1, tonumber(item.col) or tonumber(source.col) or 1)
  local annotation = vim.deepcopy(source)
  annotation.filename = filename
  annotation.lnum = lnum
  annotation.col = col
  annotation.index = idx
  annotation.list_title = list_title
  annotation.qf_text = compact_one_line(item.text or annotation.description or annotation.title, 220)
  annotation.title = compact_one_line(annotation.title or list_title or "LazyAgent ACP note", 100)
  annotation.description = compact_one_line(annotation.description or annotation.qf_text, 220)
  annotation.summary = compact_one_line(annotation.summary, 260)
  annotation.content = truncate_section(annotation.content)
  annotation.raw_output = truncate_section(annotation.raw_output)
  annotation.transcript = truncate_section(annotation.transcript)
  return annotation
end

local function sort_entries(entries)
  table.sort(entries, function(a, b)
    local ac = tonumber(a.col) or 1
    local bc = tonumber(b.col) or 1
    if ac ~= bc then
      return ac < bc
    end
    return (tonumber(a.index) or 0) < (tonumber(b.index) or 0)
  end)
end

local function add_annotation(annotation)
  local by_line = path_annotations[annotation.filename]
  if not by_line then
    by_line = {}
    path_annotations[annotation.filename] = by_line
  end
  local key = tostring(annotation.lnum)
  by_line[key] = by_line[key] or {}
  by_line[key][#by_line[key] + 1] = annotation
  sort_entries(by_line[key])
end

local function clear_buffer_marks(bufnr)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns, 0, -1)
  end
end

function M.refresh_buffer(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    return false
  end

  clear_buffer_marks(bufnr)
  local filename = normalize_path(vim.api.nvim_buf_get_name(bufnr))
  local by_line = filename and path_annotations[filename] or nil
  if not by_line then
    return false
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local applied = false
  for line_key, entries in pairs(by_line) do
    local lnum = tonumber(line_key)
    if lnum and lnum >= 1 and lnum <= line_count and type(entries) == "table" and #entries > 0 then
      local label = #entries > 1 and string.format("%s x%d", ICON, #entries) or ICON
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, lnum - 1, 0, {
        virt_text = { { label, "LazyAgentACPQuickfixAnnotation" } },
        virt_text_pos = "eol",
        hl_mode = "combine",
        priority = 120,
      })
      applied = true
    end
  end
  return applied
end

local function ensure_autocmds()
  if augroup then
    return
  end

  augroup = vim.api.nvim_create_augroup("LazyAgentACPQuickfixAnnotations", { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter", "BufReadPost" }, {
    group = augroup,
    callback = function(args)
      M.refresh_buffer(args.buf)
    end,
  })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = augroup,
    callback = setup_highlights,
  })
end

local function apply_to_loaded_buffers()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
      M.refresh_buffer(bufnr)
    end
  end
end

function M.apply(items, opts)
  setup_highlights()
  ensure_autocmds()

  path_annotations = {}
  opts = opts or {}
  local list_title = opts.title
  for idx, item in ipairs(items or {}) do
    local annotation = annotation_from_item(item, idx, list_title)
    if annotation then
      add_annotation(annotation)
    end
  end

  apply_to_loaded_buffers()
  return next(path_annotations) ~= nil
end

function M.refresh()
  local info = vim.fn.getqflist({ items = 1, title = 1 })
  return M.apply(info.items or {}, { title = info.title })
end

function M.clear(bufnr)
  if bufnr then
    clear_buffer_marks(bufnr)
    return true
  end

  path_annotations = {}
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    clear_buffer_marks(buffer)
  end
  return true
end

local function close_popup()
  if popup_win and vim.api.nvim_win_is_valid(popup_win) then
    pcall(vim.api.nvim_win_close, popup_win, true)
  end
  popup_win = nil
  popup_buf = nil
end

local function split_text_lines(text)
  text = tostring(text or "")
  if text == "" then
    return {}
  end
  return vim.split(text, "\n", { plain = true })
end

local function trim_blank_edges(lines)
  lines = type(lines) == "table" and vim.deepcopy(lines) or {}
  while #lines > 0 and vim.trim(lines[1] or "") == "" do
    table.remove(lines, 1)
  end
  while #lines > 0 and vim.trim(lines[#lines] or "") == "" do
    table.remove(lines)
  end
  return lines
end

local function normalized_match_text(text)
  text = tostring(text or "")
  text = text:gsub("\27%[[0-9;]*m", "")
  return vim.trim(text:gsub("%s+", " "))
end

local function add_pattern(patterns, value)
  local text = normalized_match_text(value)
  if text ~= "" then
    patterns[#patterns + 1] = text
  end
end

local function target_code_line(entry)
  local filename = entry and entry.filename or nil
  local lnum = tonumber(entry and entry.lnum)
  if not filename or filename == "" or not lnum or lnum <= 0 or vim.fn.filereadable(filename) ~= 1 then
    return ""
  end

  local ok, lines = pcall(vim.fn.readfile, filename, "", lnum)
  if not ok or type(lines) ~= "table" then
    return ""
  end
  return tostring(lines[lnum] or "")
end

local function match_patterns_for_entry(entry)
  local patterns = {}
  add_pattern(patterns, entry and entry.source_line)
  add_pattern(patterns, entry and entry.token)
  add_pattern(patterns, entry and entry.description)
  add_pattern(patterns, entry and entry.qf_text)

  local filename = tostring(entry and entry.filename or "")
  local lnum = tonumber(entry and entry.lnum)
  if filename ~= "" and lnum and lnum > 0 then
    local tail = vim.fn.fnamemodify(filename, ":t")
    local rel = vim.fn.fnamemodify(filename, ":.")
    for _, path in ipairs({ filename, rel, tail }) do
      if path and path ~= "" then
        add_pattern(patterns, string.format("%s:%d", path, lnum))
        add_pattern(patterns, string.format("%s#L%d", path, lnum))
        add_pattern(patterns, string.format("%s line %d", path, lnum))
        add_pattern(patterns, string.format("%s (line %d)", path, lnum))
      end
    end
    add_pattern(patterns, string.format("line %d", lnum))
  end

  add_pattern(patterns, target_code_line(entry))
  return patterns
end

local function line_matches_entry(line, patterns)
  local haystack = normalized_match_text(line)
  if haystack == "" then
    return false
  end
  for _, pattern in ipairs(patterns or {}) do
    if pattern ~= "" and (haystack == pattern or haystack:find(pattern, 1, true)) then
      return true
    end
  end
  return false
end

local function fence_bounds(lines, idx)
  local start_line = nil
  for row = idx, 1, -1 do
    if tostring(lines[row] or ""):match("^%s*```") then
      start_line = row
      break
    end
  end
  if not start_line then
    return nil, nil
  end

  local fence_count = 0
  for row = 1, start_line do
    if tostring(lines[row] or ""):match("^%s*```") then
      fence_count = fence_count + 1
    end
  end
  if fence_count % 2 == 0 then
    return nil, nil
  end

  local end_line = nil
  for row = start_line + 1, #lines do
    if tostring(lines[row] or ""):match("^%s*```") then
      end_line = row
      break
    end
  end
  return start_line, end_line
end

local function markdown_block_bounds(lines, idx)
  local start_line, end_line = fence_bounds(lines, idx)
  if start_line and end_line then
    while start_line > 1 and vim.trim(lines[start_line - 1] or "") ~= "" do
      start_line = start_line - 1
    end
    while end_line < #lines and vim.trim(lines[end_line + 1] or "") ~= "" do
      end_line = end_line + 1
    end
  else
    start_line = idx
    end_line = idx
    while start_line > 1 and vim.trim(lines[start_line - 1] or "") ~= "" do
      start_line = start_line - 1
    end
    while end_line < #lines and vim.trim(lines[end_line + 1] or "") ~= "" do
      end_line = end_line + 1
    end
  end

  if end_line - start_line + 1 > MAX_COMMENT_LINES then
    local before = math.min(20, idx - start_line)
    start_line = math.max(start_line, idx - before)
    end_line = math.min(#lines, start_line + MAX_COMMENT_LINES - 1)
  end

  local next_nonblank = end_line + 1
  while next_nonblank <= #lines and vim.trim(lines[next_nonblank] or "") == "" do
    next_nonblank = next_nonblank + 1
  end
  if end_line == idx
      and next_nonblank <= #lines
      and next_nonblank > end_line + 1
      and not tostring(lines[next_nonblank] or ""):match("^%s*#")
      and not tostring(lines[next_nonblank] or ""):match("^%s*[-*_][%-*_][%-*_]+%s*$")
  then
    local extra_end = next_nonblank
    while extra_end < #lines and vim.trim(lines[extra_end + 1] or "") ~= "" do
      extra_end = extra_end + 1
    end
    end_line = math.min(extra_end, start_line + MAX_COMMENT_LINES - 1)
  end
  return start_line, end_line
end

local function find_related_block(text, entry)
  local lines = split_text_lines(text)
  if #lines == 0 then
    return nil
  end

  local patterns = match_patterns_for_entry(entry)
  local match_idx = nil
  for idx, line in ipairs(lines) do
    if line_matches_entry(line, patterns) then
      match_idx = idx
      break
    end
  end
  if not match_idx then
    return nil
  end

  local start_line, end_line = markdown_block_bounds(lines, match_idx)
  local block = trim_blank_edges(vim.list_slice(lines, start_line, end_line))
  local cursor = math.max(1, match_idx - start_line + 1)
  return block, cursor
end

local function fallback_comment(entry)
  local lines = {}
  local code = target_code_line(entry)
  if code ~= "" then
    local lang = nil
    local ft = vim.filetype.match({ filename = entry.filename })
    if ft then
      lang = vim.treesitter.language.get_lang(ft) or ft
    end
    lines[#lines + 1] = string.format("```%s", lang or "")
    lines[#lines + 1] = code
    lines[#lines + 1] = "```"
    lines[#lines + 1] = ""
  end

  local comment = tostring(entry.description or entry.qf_text or entry.summary or "")
  if comment ~= "" then
    vim.list_extend(lines, split_text_lines(comment))
  end
  if #lines == 0 then
    lines[#lines + 1] = "(no comment)"
  end
  return trim_blank_edges(lines), code ~= "" and 2 or 1
end

local function related_comment(entry)
  for _, text in ipairs({
    entry and entry.content,
    entry and entry.raw_output,
    entry and entry.transcript,
    entry and entry.summary,
    entry and entry.source_line,
    entry and entry.description,
  }) do
    local block, cursor = find_related_block(text, entry)
    if block and #block > 0 then
      return block, cursor
    end
  end
  return fallback_comment(entry)
end

local function popup_lines(entries)
  local lines = {}
  local cursor_line = 1
  for idx, entry in ipairs(entries or {}) do
    local block, cursor = related_comment(entry)
    if idx > 1 then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "---"
      lines[#lines + 1] = ""
    end
    local offset = #lines
    vim.list_extend(lines, block)
    if idx == 1 then
      cursor_line = offset + math.max(1, tonumber(cursor) or 1)
    end
  end

  lines = trim_blank_edges(lines)
  if #lines == 0 then
    return { "(no comment)" }, 1
  end
  return lines, math.min(#lines, math.max(1, cursor_line))
end

local function popup_size(lines)
  local max_width = math.max(40, math.floor(vim.o.columns * 0.62))
  local width = 40
  for _, line in ipairs(lines) do
    width = math.max(width, math.min(max_width, vim.fn.strdisplaywidth(line) + 2))
  end
  local height = math.min(math.max(4, #lines), math.max(6, math.floor(vim.o.lines * 0.45)))
  return width, height
end

local function open_popup(lines, cursor_line)
  close_popup()
  popup_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[popup_buf].bufhidden = "wipe"
  vim.bo[popup_buf].buftype = "nofile"
  vim.bo[popup_buf].swapfile = false
  vim.bo[popup_buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(popup_buf, 0, -1, false, lines)
  vim.bo[popup_buf].modifiable = false
  pcall(vim.treesitter.start, popup_buf, "markdown")

  local width, height = popup_size(lines)
  local ok, win = pcall(vim.api.nvim_open_win, popup_buf, true, {
    relative = "cursor",
    row = 1,
    col = 1,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " ACP quickfix note ",
    title_pos = "left",
  })
  if not ok or not win then
    win = vim.api.nvim_open_win(popup_buf, true, {
      relative = "editor",
      row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
      col = math.max(0, math.floor((vim.o.columns - width) / 2)),
      width = width,
      height = height,
      style = "minimal",
      border = "rounded",
      title = " ACP quickfix note ",
      title_pos = "left",
    })
  end
  popup_win = win
  vim.wo[popup_win].wrap = true
  vim.wo[popup_win].conceallevel = 2
  pcall(vim.api.nvim_win_set_cursor, popup_win, { math.max(1, tonumber(cursor_line) or 1), 0 })

  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, close_popup, {
      buffer = popup_buf,
      nowait = true,
      silent = true,
      noremap = true,
      desc = "Close LazyAgent ACP quickfix note",
    })
  end
  return true
end

function M.annotations_at(bufnr, lnum)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return {}
  end
  local filename = normalize_path(vim.api.nvim_buf_get_name(bufnr))
  local by_line = filename and path_annotations[filename] or nil
  if not by_line then
    return {}
  end
  return by_line[tostring(lnum)] or {}
end

function M.show_at_cursor(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local lnum = opts.lnum or (vim.api.nvim_win_get_cursor(0)[1])
  if next(path_annotations) == nil then
    M.refresh()
  else
    M.refresh_buffer(bufnr)
  end

  local entries = M.annotations_at(bufnr, lnum)
  if #entries == 0 then
    vim.notify("No LazyAgent ACP quickfix note on this line", vim.log.levels.INFO)
    return false
  end

  local lines, cursor_line = popup_lines(entries)
  return open_popup(lines, cursor_line)
end

function M.close_popup()
  close_popup()
end

function M.namespace()
  return ns
end

return M
