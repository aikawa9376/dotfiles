local M = {}
local jobs = require('git.features.highlight_jobs')
local syntax_word_diff = require('git.features.syntax_word_diff')
local delta_word_diff = require('git.features.delta_word_diff')
local highlight_sources = require('git.features.highlight_sources')

-- 'diffs':   diffs.nvim-style group diff -> line pairing -> byte diff
-- 'delta': delta 0.19.2 token alignment and forward line pairing
-- 'treesitter': paired syntax lists and atoms, with token-only backgrounds
-- 'github':  sequential line pairing (old[i] <-> new[i])
M.config = { word_diff_style = 'treesitter', changed_fg = 'syntax' }

local WORD_DIFF_STYLES = { 'diffs', 'delta', 'treesitter', 'github' }

local PRIORITY_BG = 200
local PRIORITY_SYNTAX = 210
local spinner_frames = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }
local spinner_frame = 1

-- PHP hunks often omit both the opening tag and the enclosing class. Reuse
-- verified complete trees rather than guessing whether a fragment is HTML,
-- a free function, or a class method. Other languages retain hunk comparison.
local function comparison_sources(cached)
  local context = cached.prepared and cached.prepared.comparison_context
  return context and context.sources or cached.sources, context
end

local function comparison_version(cached)
  local sources, context = comparison_sources(cached)
  local version = syntax_word_diff.version(sources and sources.old, sources and sources.new)
  if context then
    return version .. ':' .. syntax_word_diff.version(cached.sources.old, cached.sources.new)
  end
  return version
end

-- --- Utilities ---

local Utils = {}

-- Tokenize string into words and whitespace/punctuation
function Utils.tokenize(str)
  local tokens = {}
  local ranges = {} -- {start_byte, end_byte} 1-based, inclusive
  local i = 1
  local len = #str

  while i <= len do
    local s, e

    -- 1. Whitespace sequence
    s, e = str:find('^%s+', i)
    if s then
      table.insert(tokens, str:sub(s, e))
      table.insert(ranges, {s, e})
      i = e + 1
    else
      -- 2. Alphanumeric sequence (Word)
      s, e = str:find('^[%w_]+', i)
      if s then
        table.insert(tokens, str:sub(s, e))
        table.insert(ranges, {s, e})
        i = e + 1
      else
        -- 3. Single character (Punctuation or UTF-8)
        local byte = str:byte(i)
        local char_len = 1
        if byte >= 240 then char_len = 4
        elseif byte >= 224 then char_len = 3
        elseif byte >= 192 then char_len = 2
        end

        e = i + char_len - 1
        if e > len then e = len end

        table.insert(tokens, str:sub(i, e))
        table.insert(ranges, {i, e})
        i = e + 1
      end
    end
  end
  return tokens, ranges
end

function Utils.common_prefix_len(str1, str2)
  local len = math.min(#str1, #str2)
  for i = 1, len do
    if str1:byte(i) ~= str2:byte(i) then
      return i - 1
    end
  end
  return len
end

function Utils.merge_ranges(ranges, text)
  if #ranges < 2 then return ranges end
  table.sort(ranges, function(a, b) return a[1] < b[1] end)

  local merged = { ranges[1] }
  for i = 2, #ranges do
    local prev = merged[#merged]
    local curr = ranges[i]
    local gap_start = prev[2] + 1
    local gap_end = curr[1] - 1

    local can_merge = false
    if gap_start > gap_end then
      can_merge = true
    else
      local gap_text = text:sub(gap_start, gap_end)
      if gap_text:match("^%s*$") then
        can_merge = true
      end
    end

    if can_merge then
      prev[2] = math.max(prev[2], curr[2])
    else
      table.insert(merged, curr)
    end
  end
  return merged
end

function Utils.compute_word_diffs(old_text, new_text)
  local old_tokens, old_ranges = Utils.tokenize(old_text)
  local new_tokens, new_ranges = Utils.tokenize(new_text)

  local old_lines = table.concat(old_tokens, '\n') .. '\n'
  local new_lines = table.concat(new_tokens, '\n') .. '\n'

  local ok, result = pcall(vim.diff, old_lines, new_lines, { result_type = 'indices' })
  if not ok or type(result) ~= 'table' then return {} end

  local byte_diffs = {}

  for _, d in ipairs(result) do
      local o_start, o_count, n_start, n_count = unpack(d)
      local diff_entry = {}
      local o_byte_start, o_byte_end, n_byte_start, n_byte_end
      local sub_old_text = ""
      local sub_new_text = ""

      if o_count > 0 then
          local first = o_start
          local last = o_start + o_count - 1
          if old_ranges[first] and old_ranges[last] then
            o_byte_start = old_ranges[first][1]
            o_byte_end = old_ranges[last][2]
            sub_old_text = old_text:sub(o_byte_start, o_byte_end)
          end
      end

      if n_count > 0 then
          local first = n_start
          local last = n_start + n_count - 1
          if new_ranges[first] and new_ranges[last] then
            n_byte_start = new_ranges[first][1]
            n_byte_end = new_ranges[last][2]
            sub_new_text = new_text:sub(n_byte_start, n_byte_end)
          end
      end

      -- Handle indentation changes by trimming common prefix
      if sub_old_text ~= "" and sub_new_text ~= "" then
         local old_ws_match = sub_old_text:match("^(%s+)")
         local new_ws_match = sub_new_text:match("^(%s+)")

         if old_ws_match and new_ws_match then
           local common_len = Utils.common_prefix_len(old_ws_match, new_ws_match)
           if common_len > 0 then
             if o_byte_start then o_byte_start = o_byte_start + common_len end
             if n_byte_start then n_byte_start = n_byte_start + common_len end
           end
         end
      end

      if o_byte_start and o_byte_end and o_byte_start <= o_byte_end then
        diff_entry[1] = o_byte_start
        diff_entry[2] = o_byte_end
      end

      if n_byte_start and n_byte_end and n_byte_start <= n_byte_end then
        diff_entry[3] = n_byte_start
        diff_entry[4] = n_byte_end
      end

      if diff_entry[1] or diff_entry[3] then
        table.insert(byte_diffs, diff_entry)
      end
  end

  return byte_diffs
end

local DIFFOPT_FLAGS = {
  iwhite = 'ignore_whitespace_change',
  iwhiteall = 'ignore_whitespace',
  iwhiteeol = 'ignore_whitespace_change_at_eol',
  iblank = 'ignore_blank_lines',
}

function Utils.diff_opts()
  local opts = {}
  for _, item in ipairs(vim.split(vim.o.diffopt, ',', { plain = true })) do
    local key, val = item:match('^(%w+):(.+)$')
    if key == 'algorithm' then
      opts.algorithm = val
    elseif key == 'linematch' then
      opts.linematch = tonumber(val)
    elseif DIFFOPT_FLAGS[item] then
      opts[DIFFOPT_FLAGS[item]] = true
    end
  end
  return opts
end

function Utils.diff_indices(old_text, new_text, diff_opts)
  local vim_opts = { result_type = 'indices' }
  if diff_opts then
    if diff_opts.algorithm then
      vim_opts.algorithm = diff_opts.algorithm
    end
    if diff_opts.linematch then
      vim_opts.linematch = diff_opts.linematch
    end
  end

  local ok, result = pcall(vim.diff, old_text, new_text, vim_opts)
  if not ok or type(result) ~= 'table' then
    return {}
  end

  local hunks = {}
  for _, h in ipairs(result) do
    hunks[#hunks + 1] = {
      old_start = h[1],
      old_count = h[2],
      new_start = h[3],
      new_count = h[4],
    }
  end
  return hunks
end

function Utils.split_bytes(str)
  local bytes = {}
  for i = 1, #str do
    bytes[#bytes + 1] = str:sub(i, i)
  end
  return bytes
end

function Utils.extract_change_groups(hunk_lines, include_one_sided)
  local groups = {}
  local del_buf = {}
  local add_buf = {}
  local in_del = false

  local function flush()
    if #del_buf > 0 and #add_buf > 0 or include_one_sided and (#del_buf > 0 or #add_buf > 0) then
      groups[#groups + 1] = { del_lines = del_buf, add_lines = add_buf }
    end
    del_buf = {}
    add_buf = {}
  end

  for i, line in ipairs(hunk_lines) do
    local prefix = line:sub(1, 1)
    if prefix == '-' then
      if not in_del and #add_buf > 0 then
        flush()
      end
      in_del = true
      del_buf[#del_buf + 1] = { idx = i, text = line:sub(2) }
    elseif prefix == '+' then
      in_del = false
      add_buf[#add_buf + 1] = { idx = i, text = line:sub(2) }
    elseif line:match('^\\ No newline at end of file') then
      -- The marker occupies a display row but does not split a replacement.
    else
      flush()
      in_del = false
    end
  end

  flush()
  return groups
end

function Utils.drop_whitespace_spans(spans, line, diff_opts)
  local ignore_all = diff_opts and diff_opts.ignore_whitespace
  local ignore_eol = diff_opts and diff_opts.ignore_whitespace_change_at_eol
  if not (ignore_all or ignore_eol) then
    return spans
  end

  local kept = {}
  for _, span in ipairs(spans) do
    local text = line:sub(span.col_start, span.col_end - 1)
    local whitespace_only = text:match('^%s*$') ~= nil
    local drop
    if ignore_all then
      drop = whitespace_only
    else
      drop = whitespace_only and span.col_end > #line
    end
    if not drop then
      kept[#kept + 1] = span
    end
  end
  return kept
end

function Utils.char_diff_pair(old_line, new_line, del_idx, add_idx, diff_opts)
  local old_text = table.concat(Utils.split_bytes(old_line), '\n') .. '\n'
  local new_text = table.concat(Utils.split_bytes(new_line), '\n') .. '\n'
  local char_opts = diff_opts
  if diff_opts and diff_opts.linematch then
    char_opts = { algorithm = diff_opts.algorithm }
  end

  local del_spans = {}
  local add_spans = {}
  for _, ch in ipairs(Utils.diff_indices(old_text, new_text, char_opts)) do
    if ch.old_count > 0 then
      del_spans[#del_spans + 1] = {
        line = del_idx,
        col_start = ch.old_start,
        col_end = ch.old_start + ch.old_count,
      }
    end
    if ch.new_count > 0 then
      add_spans[#add_spans + 1] = {
        line = add_idx,
        col_start = ch.new_start,
        col_end = ch.new_start + ch.new_count,
      }
    end
  end

  return Utils.drop_whitespace_spans(del_spans, old_line, diff_opts),
    Utils.drop_whitespace_spans(add_spans, new_line, diff_opts)
end

function Utils.pair_group_lines(group, diff_opts)
  if #group.del_lines == 1 and #group.add_lines == 1 then
    return { { del = group.del_lines[1], add = group.add_lines[1] } }
  end

  local old_texts = {}
  for _, line in ipairs(group.del_lines) do
    old_texts[#old_texts + 1] = line.text
  end

  local new_texts = {}
  for _, line in ipairs(group.add_lines) do
    new_texts[#new_texts + 1] = line.text
  end

  local pair_opts = diff_opts
  if diff_opts and diff_opts.linematch then
    pair_opts = { algorithm = diff_opts.algorithm }
  end

  local pairs = {}
  local old_block = table.concat(old_texts, '\n') .. '\n'
  local new_block = table.concat(new_texts, '\n') .. '\n'
  for _, lh in ipairs(Utils.diff_indices(old_block, new_block, pair_opts)) do
    local count = (lh.old_count == lh.new_count) and lh.old_count or math.min(lh.old_count, lh.new_count)
    for k = 0, count - 1 do
      local del = group.del_lines[lh.old_start + k]
      local add = group.add_lines[lh.new_start + k]
      if del and add then
        pairs[#pairs + 1] = { del = del, add = add }
      end
    end
  end
  return pairs
end

function Utils.compute_diffs_style_word_diffs(hunk_lines)
  local groups = Utils.extract_change_groups(hunk_lines)
  if #groups == 0 then
    return nil
  end

  local diff_opts = Utils.diff_opts()
  local add_spans = {}
  local del_spans = {}

  for _, group in ipairs(groups) do
    for _, pair in ipairs(Utils.pair_group_lines(group, diff_opts)) do
      local ds, as = Utils.char_diff_pair(pair.del.text, pair.add.text, pair.del.idx, pair.add.idx, diff_opts)
      vim.list_extend(del_spans, ds)
      vim.list_extend(add_spans, as)
    end
  end

  if #add_spans == 0 and #del_spans == 0 then
    return nil
  end
  return { add_spans = add_spans, del_spans = del_spans }
end

function Utils.normalize_ws(line, diff_opts)
  if diff_opts.ignore_whitespace then
    return (line:gsub('%s+', ''))
  end
  if diff_opts.ignore_whitespace_change then
    return (line:gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', ''))
  end
  if diff_opts.ignore_whitespace_change_at_eol then
    return (line:gsub('%s+$', ''))
  end
  return line
end

function Utils.whitespace_only_lines(hunk_lines)
  local diff_opts = Utils.diff_opts()
  if
    not (
      diff_opts.ignore_whitespace
      or diff_opts.ignore_whitespace_change
      or diff_opts.ignore_whitespace_change_at_eol
    )
  then
    return {}
  end

  local result = {}
  for _, group in ipairs(Utils.extract_change_groups(hunk_lines)) do
    for _, pair in ipairs(Utils.pair_group_lines(group, diff_opts)) do
      if Utils.normalize_ws(pair.del.text, diff_opts) == Utils.normalize_ws(pair.add.text, diff_opts) then
        result[pair.del.idx] = true
        result[pair.add.idx] = true
      end
    end
  end
  return result
end

-- --- Parser ---

local Parser = {}

function Parser.get_lang_info(filename)
  local ft = vim.filetype.match({ filename = filename })
  if not ft then return nil, nil end

  local lang = vim.treesitter.language.get_lang(ft)
  if lang and pcall(vim.treesitter.language.inspect, lang) then
    return ft, lang
  end
  return ft, nil
end

function Parser.parse_buffer(bufnr, first_line)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local hunks = {}
  local state = {
    filename = nil,
    lang = nil,
    ft = nil,
    hunk_start = nil,
    lines = {}
  }

  local function flush()
    if state.hunk_start and #state.lines > 0 then
      table.insert(hunks, {
        filename = state.filename,
        lang = state.lang,
        ft = state.ft,
        start_line = state.hunk_start,
        old_start = state.old_start, new_start = state.new_start,
        lines = state.lines,
      })
    end
    state.hunk_start = nil
    state.lines = {}
  end

  for i = first_line or 1, #lines do
    local line = lines[i]
    local filename = line:match('^[%s]*[MADRCU%?!][MADRCU%?!%s]*%s+(.+)$') or line:match('^diff %-%-git a/.+ b/(.+)$')

    if filename then
      -- Handle rename syntax "old -> new"
      local _, new_name = filename:match('^(.-)%s+%-%>%s+(.+)$')
      if new_name then filename = new_name end

      flush()
      state.filename = filename
      state.ft, state.lang = Parser.get_lang_info(filename)

    elseif line:match('^@@.-@@') then
      flush()
      state.hunk_start = i -- line index of the header line
      local old, new = line:match('^@@ %-(%d+),?%d* %+(%d+),?%d* @@')
      state.old_start, state.new_start = tonumber(old), tonumber(new)
    elseif state.hunk_start then
      local prefix = line:sub(1, 1)
      if prefix == ' ' or prefix == '+' or prefix == '-' or line:match('^\\ No newline at end of file') then
        table.insert(state.lines, line)
      elseif line == '' or line:match('^[%s]*[MADRCU%?!]') or line:match('^diff ') or line:match('^index ') or line:match('^Binary ') then
        flush()
        state.filename = nil
        state.lang = nil
        state.ft = nil
      end
    end
  end
  flush()

  return hunks
end

-- --- Highlighter ---

local Highlighter = {}
local recording = {}

function Highlighter.record_mark(cached, bufnr, ns, row, col, options)
  local key = table.concat({ row, col, options.end_row or '', options.end_col or '', options.hl_group or '',
    options.priority or '', options.hl_eol and 1 or 0, options.virt_text_pos or '',
    options.virt_text_pos == 'eol' and 'loading' or options.virt_text and vim.mpack.encode(options.virt_text) or '' }, '\0')
  local mark = cached.mark_map[key]
  if not mark then
    local absolute = vim.tbl_extend('force', {}, options)
    if absolute.end_row then absolute.end_row = absolute.end_row + cached.start_line end
    mark = { row = row, col = col, opts = options, key = key }
    mark.id = vim.api.nvim_buf_set_extmark(bufnr, ns, cached.start_line + row, col, absolute)
    cached.marks[#cached.marks + 1], cached.mark_map[key] = mark, mark
  end
  mark.generation = cached.mark_generation
  if options.virt_text_pos == 'eol' then cached.loading_mark = mark end
  return mark.id
end

function Highlighter.set_mark(bufnr, ns, row, col, options)
  local cached = recording[bufnr]
  if not cached then return vim.api.nvim_buf_set_extmark(bufnr, ns, row, col, options) end
  options = vim.tbl_extend('force', {}, options)
  if options.end_row then options.end_row = options.end_row - cached.start_line end
  return Highlighter.record_mark(cached, bufnr, ns, row - cached.start_line, col, options)
end

function Highlighter.setup_groups()
  -- Diff syntax supplies red/green foregrounds below our extmarks. An ERROR
  -- tree may have no capture for the first key/keyword; restore source color
  -- independently of capture coverage. Keep backgrounds owned by diff spans.
  local normal = vim.api.nvim_get_hl(0, { name = 'Normal', link = false })
  vim.api.nvim_set_hl(0, 'FugitiveExtCode', { fg = normal.fg, ctermfg = normal.ctermfg })
  -- Define custom groups
  -- DiffAdd bg: #23384C, DiffDelete bg: #321e1e (approx)
  vim.api.nvim_set_hl(0, 'FugitiveExtAdd', { bg = "#23384C", default = true })
  vim.api.nvim_set_hl(0, 'FugitiveExtDelete', { bg = "#321e1e", default = true })
  vim.api.nvim_set_hl(0, 'GitStatusConflictLine', { bg = '#453e2b', default = true })

  -- Word diff highlights (intra-line)
  vim.api.nvim_set_hl(0, 'FugitiveExtAddText', { bg = "#005f5f", default = true })
  vim.api.nvim_set_hl(0, 'FugitiveExtDeleteText', { bg = "#8c3b40", default = true })
  vim.api.nvim_set_hl(0, 'FugitiveExtAddPrefix', { link = 'GitSignsAdd', default = true })
  vim.api.nvim_set_hl(0, 'FugitiveExtDeletePrefix', { link = 'GitSignsDelete', default = true })
  -- Difftastic emits ANSI bright red/green on dark backgrounds and ordinary
  -- red/green on light ones. Resolve those through the theme's terminal palette.
  local red, green = vim.o.background == 'dark' and 9 or 1, vim.o.background == 'dark' and 10 or 2
  vim.api.nvim_set_hl(0, 'FugitiveExtNovelDelete', {
    fg = vim.g['terminal_color_' .. red] or (red == 9 and '#ff5555' or '#aa0000'), ctermfg = red,
  })
  vim.api.nvim_set_hl(0, 'FugitiveExtNovelAdd', {
    fg = vim.g['terminal_color_' .. green] or (green == 10 and '#55ff55' or '#00aa00'), ctermfg = green,
  })
end

function Highlighter.capture_treesitter(source, lang, query, checkpoint, projection)
  local captures = {}
  if not source or not query or source.code == '' then return captures end
  local count = 0
  local first_row = projection and projection.offset or 0
  local last_row = first_row + #(projection and projection.original or source.lines)
  for id, node, metadata in query:iter_captures(source.tree:root(), source.code, first_row, last_row) do
    local capture_name = '@' .. query.captures[id] .. '.' .. lang
    local sr, sc, er, ec = node:range()

    -- A multiline capture must not cross inserted opposite-side rows.
    for row = math.max(sr, first_row), math.min(er, last_row - 1) do
      local projected = row - (projection and projection.offset or 0)
      local first = row == sr and sc or 0
      local last = row == er and ec or #(source.lines[row + 1] or '')
      local priority = (tonumber(metadata.priority) or 100) + PRIORITY_SYNTAX
      local line = (projection and projection.original or source.lines)[projected + 1]
      last = math.min(last, #(line or ''))
      if line and last > first then
        captures[#captures + 1] = { row = projected + 1, first = first, last = last, group = capture_name, priority = priority }
      end
      count = count + 1
      if count % 128 == 0 then checkpoint() end
    end
  end
  return captures
end

function Highlighter.prepare(cached, code, lang, query, bufnr)
  if cached.preparing and cached.preparing.query == query and cached.preparing.source_key == cached.source_key then return false end
  if cached.prepared and cached.prepared.query == query and cached.prepared.source_key == cached.source_key then return true end
  cached.sources = cached.sources or {}
  local job = { query = query, source_key = cached.source_key }
  cached.preparing = job
  local function valid()
    return cached.active and cached.preparing == job and vim.api.nvim_buf_is_loaded(bufnr)
  end
  local function parsed()
    if not valid() then return end
    local colored, projections = {}, {}
    local function capture()
      jobs.run(function(checkpoint)
        local result = { query = query, source_key = job.source_key, captures = {} }
        if lang == 'php' and colored.old and colored.new then
          result.comparison_context = { sources = colored, projections = projections }
        end
        for _, side in ipairs({ 'old', 'new' }) do
          result.captures[side] = Highlighter.capture_treesitter(
            colored[side] or cached.sources[side], lang, query, checkpoint, projections[side])
          checkpoint()
        end
        return result
      end, valid, function(result, err)
        if not valid() then return end
        cached.preparing = nil
        if not result then error(err) end
        cached.prepared = result
        cached.preparation_version = (cached.preparation_version or 0) + 1
        syntax_word_diff.request_refresh(bufnr)
      end)
    end
    if not cached.color_spec or not lang or (not query and lang ~= 'php') then capture(); return end
    cached.source_session.request(cached.color_spec, valid, function(full)
      if not valid() then return end
      if not full then capture(); return end
      local remaining = 2
      local function ready()
        remaining = remaining - 1
        if remaining == 0 then capture() end
      end
      for _, side in ipairs({ 'old', 'new' }) do
        syntax_word_diff.parse_async(full[side], lang, valid, function(source)
          if not valid() then return end
          local original = code[side]
          local offset = math.max(0, (cached.source_starts[side] or 1) - 1)
          jobs.run(function(checkpoint)
            -- A stale patch, filter or concurrently edited file must not lend
            -- another source's colors to these rows. Verify every projected row.
            if not source then return false end
            for row, line in ipairs(original) do
              if source.lines[offset + row] ~= line then return false end
              if row % 128 == 0 then checkpoint() end
            end
            return true
          end, valid, function(matches, err)
            if not valid() then return end
            if matches == nil then error(err) end
            if matches then
              colored[side] = source
              projections[side] = { offset = offset, original = original }
            end
            ready()
          end)
        end)
      end
    end)
  end
  if cached.parsed then parsed(); return false end
  local remaining = 2
  for _, side in ipairs({ 'old', 'new' }) do
    syntax_word_diff.parse_async(code[side], lang, valid, function(source)
      cached.sources[side] = source
      remaining = remaining - 1
      if remaining == 0 then cached.parsed = true; parsed() end
    end)
  end
  return false
end

function Highlighter.apply_treesitter(bufnr, ns, captures, line_map, emit, checkpoint)
  emit = emit or Highlighter.set_mark
  for i, capture in ipairs(captures or {}) do
    local buf_row = line_map[capture.row]
    if buf_row then
      emit(bufnr, ns, buf_row, capture.first + 1, {
        end_col = capture.last + 1, hl_group = capture.group, priority = capture.priority,
      })
    end
    if checkpoint and i % 128 == 0 then checkpoint() end
  end
end

function Highlighter.finish_loading(cached, bufnr, ns)
  if cached.preparing or cached.foreground_job or cached.paint_job or cached.comparison_pending then return end
  for i = #cached.marks, 1, -1 do
    local mark = cached.marks[i]
    if mark.opts.virt_text_pos == 'eol' then
      vim.api.nvim_buf_del_extmark(bufnr, ns, mark.id)
      cached.mark_map[mark.key] = nil
      if cached.loading_mark == mark then cached.loading_mark = nil end
      table.remove(cached.marks, i)
    end
  end
end

function Highlighter.foreground(cached, bufnr, ns, colors)
  local prepared = cached.prepared
  if cached.foreground_ready == prepared
    or cached.foreground_job and cached.foreground_job.prepared == prepared then
    for _, mark in ipairs(cached.marks) do
      if (mark.opts.hl_group or ''):match('^@') then mark.generation = cached.mark_generation end
    end
    return
  end
  local job = { prepared = prepared }
  cached.foreground_job = job
  local function valid()
    return cached.active and cached.foreground_job == job and cached.query == prepared.query
      and vim.api.nvim_buf_is_loaded(bufnr)
  end
  jobs.run(function(checkpoint)
    local count = 0
    local function emit(_, _, row, col, options)
      Highlighter.record_mark(cached, bufnr, ns, row, col, options)
      count = count + 1
      if count % 64 == 0 then checkpoint() end
    end
    for _, side in ipairs({ 'old', 'new' }) do
      Highlighter.apply_treesitter(bufnr, ns, prepared.captures[side], colors[side], emit, checkpoint)
    end
    return true
  end, valid, function(result, err)
    if not valid() then return end
    cached.foreground_job = nil
    if not result then error(err) end
    cached.foreground_ready = prepared
    Highlighter.finish_loading(cached, bufnr, ns)
  end)
end

function Highlighter.apply_legacy(bufnr, hunk, regions)
  if not hunk.ft then return end

  local ft_clean = hunk.ft:gsub('[^%w]', '_')
  local ft_group = 'FugitiveExt_' .. ft_clean
  local included_var = 'fugitive_ext_included_' .. ft_group

  -- Include syntax if not already done
  local is_included = false
  pcall(function() is_included = vim.api.nvim_buf_get_var(bufnr, included_var) end)

  if not is_included then
    local had_syntax, current_syntax = pcall(vim.api.nvim_buf_get_var, bufnr, 'current_syntax')
    vim.b.current_syntax = nil
    vim.cmd(string.format('silent! syntax include @%s syntax/%s.vim', ft_group, hunk.ft))
    vim.b.current_syntax = had_syntax and current_syntax or nil
    vim.api.nvim_buf_set_var(bufnr, included_var, true)
  end

  -- The header's one-based row precedes the code body; include the final EOL.
  local start_row = hunk.start_line + 1
  local last_line = hunk.start_line + #hunk.lines
  local region_name = 'FugitiveExtRegion_' .. start_row

  -- A Normal parent clears diff foregrounds for uncaptured prose while the
  -- contained Vim syntax still owns its keyword/string colors.
  vim.cmd('highlight default link ' .. region_name .. ' Normal')
  vim.cmd(string.format('syntax region %s start=/\\%%%dl^/ end=/\\%%%dl$/ contains=@%s containedin=ALL keepend', region_name, start_row, last_line, ft_group))
  table.insert(regions, region_name)
end

function Highlighter.apply_background(bufnr, ns, hunk)
  for i, line in ipairs(hunk.lines) do
    local prefix = line:sub(1, 1)
    local buf_line = hunk.start_line + i - 1

    if M.config.word_diff_style == 'treesitter' and (hunk.lang or not hunk.ft) and #line > 1 then
      Highlighter.set_mark(bufnr, ns, buf_line, 1, {
        end_col = #line, hl_group = 'FugitiveExtCode', priority = PRIORITY_SYNTAX,
      })
    end

    if prefix == '+' or prefix == '-' then
      local hl_group = (prefix == '+') and 'FugitiveExtAdd' or 'FugitiveExtDelete'
      local prefix_hl = (prefix == '+') and 'FugitiveExtAddPrefix' or 'FugitiveExtDeletePrefix'

      -- Structural style colors syntax spans only, including one-sided edits.
      if M.config.word_diff_style ~= 'treesitter' then
        pcall(Highlighter.set_mark, bufnr, ns, buf_line, 0, {
          end_row = buf_line + 1,
          end_col = 0,
          hl_group = hl_group,
          hl_eol = true,
          priority = PRIORITY_BG,
          strict = false,
        })
      end

      -- Hide prefix
      pcall(Highlighter.set_mark, bufnr, ns, buf_line, 0, {
        virt_text = { { M.config.word_diff_style == 'treesitter' and '▏' or ' ', prefix_hl } },
        virt_text_pos = 'overlay',
        priority = PRIORITY_BG + 1,
      })
    end
  end
end

function Highlighter.apply_diffs_style_word_diffs(bufnr, ns, hunk)
  local intra = Utils.compute_diffs_style_word_diffs(hunk.lines)
  if not intra then
    return
  end
  local whitespace_only = Utils.whitespace_only_lines(hunk.lines)

  local function apply_span(span, hl_group)
    local line = hunk.lines[span.line]
    if not line or whitespace_only[span.line] then
      return
    end

    local buf_line = hunk.start_line + span.line - 1
    pcall(Highlighter.set_mark, bufnr, ns, buf_line, span.col_start, {
      end_col = span.col_end,
      hl_group = hl_group,
      priority = PRIORITY_SYNTAX + 150,
    })
  end

  for _, span in ipairs(intra.del_spans) do
    apply_span(span, 'FugitiveExtDeleteText')
  end
  for _, span in ipairs(intra.add_spans) do
    apply_span(span, 'FugitiveExtAddText')
  end
end

function Highlighter.apply_word_diffs(bufnr, ns, group_old, group_new, group_old_lines, group_new_lines)
  if #group_old == 0 or #group_new == 0 then return end
  local changes
  if M.config.word_diff_style == 'github' then
    changes = { old = {}, new = {} }
    for i = 1, math.min(#group_old, #group_new) do
      local old, new = {}, {}
      for _, diff in ipairs(Utils.compute_word_diffs(group_old[i], group_new[i])) do
        if diff[1] then old[#old + 1] = { diff[1], diff[2] } end
        if diff[3] then new[#new + 1] = { diff[3], diff[4] } end
      end
      changes.old[i] = Utils.merge_ranges(old, group_old[i])
      changes.new[i] = Utils.merge_ranges(new, group_new[i])
    end
  else
    changes = delta_word_diff.compare(group_old, group_new)
  end
  for _, side in ipairs({ { changes.old, group_old_lines, 'FugitiveExtDeleteText' },
    { changes.new, group_new_lines, 'FugitiveExtAddText' } }) do
    for row, ranges in pairs(side[1]) do
      for _, range in ipairs(ranges) do
        Highlighter.set_mark(bufnr, ns, side[2][row], range[1], {
          end_col = range[2] + 1, hl_group = side[3], priority = PRIORITY_SYNTAX + 150,
        })
      end
    end
  end
end

function Highlighter.apply_block_word_diffs(bufnr, ns, hunk, sources, layout, emit, checkpoint, context)
  emit = emit or Highlighter.set_mark
  checkpoint = checkpoint or function() end
  -- Compare once across context as well as replacement groups. This retains
  -- structural anchors around inserted statements and paired delimiters.
  local compared = context and context.sources or sources
  local structural, pending
  -- A tagless PHP fragment is valid HTML text according to the PHP grammar.
  -- If complete context is unavailable, prefer word matching to painting that
  -- entire text atom as changed. Never guess an opening tag or class wrapper.
  local tagless_php = hunk.lang == 'php' and not context
    and not table.concat(layout.code.old, '\n'):find('<?', 1, true)
    and not table.concat(layout.code.new, '\n'):find('<?', 1, true)
  if not tagless_php then
    structural, pending = syntax_word_diff.compare_async(compared.old, compared.new, bufnr)
  end
  local loading = pending
  for _, group in ipairs(layout.groups) do
    checkpoint()
    local rows, texts, displayed = group.rows, group.texts, group.displayed
    local changes = structural
    local full_hunk = changes ~= nil
    if not changes and pending then
      -- Wait for the complete comparison instead of starting duplicate graph
      -- searches for fragments. Interim text ranges stay muted.
      group.fallback = group.fallback or syntax_word_diff.text_fallback(texts.old, texts.new)
      changes = group.fallback
    elseif not changes and hunk.lang == 'php' then
      -- Broken complete files cannot establish PHP structural correspondence;
      -- reparsing a tagless method as HTML would incorrectly color everything.
      group.fallback = group.fallback or syntax_word_diff.text_fallback(texts.old, texts.new)
      changes = group.fallback
    elseif not changes then
      -- A cut-off enclosing function or a difficult region must not force
      -- independent comments/expressions elsewhere onto text matching.
      local recovering
      changes, recovering = syntax_word_diff.recover(sources.old, sources.new, texts.old, texts.new, hunk.lang, bufnr)
      loading = loading or recovering
    end
    if hunk.lang and group.whitespace_only then
      changes = { old = {}, new = {}, emphasis = { old = {}, new = {} } }
    end
    for _, side in ipairs({ 'old', 'new' }) do
      for index, relative in ipairs(displayed[side]) do
        if index % 32 == 0 then checkpoint() end
        local buf_row = hunk.start_line + relative
        local row = full_hunk and rows[side][index] or index
        if full_hunk and context then row = row + context.projections[side].offset end
        local line = texts[side][index]
        for _, level in ipairs({
          { changes[side], side == 'old' and 'FugitiveExtDelete' or 'FugitiveExtAdd', 150 },
          { changes.emphasis[side], side == 'old' and 'FugitiveExtDeleteText' or 'FugitiveExtAddText', 151 },
        }) do
          for _, range in ipairs(Utils.merge_ranges(vim.deepcopy(level[1][row] or {}), line)) do
            emit(bufnr, ns, buf_row, range[1], {
              end_col = range[2] + 1, hl_group = level[2], priority = PRIORITY_SYNTAX + level[3],
            })
            if M.config.changed_fg == 'difft' then
              emit(bufnr, ns, buf_row, range[1], {
                end_col = range[2] + 1,
                hl_group = side == 'old' and 'FugitiveExtNovelDelete' or 'FugitiveExtNovelAdd',
                priority = PRIORITY_SYNTAX + level[3],
              })
            end
          end
        end
      end
    end
  end
  return loading
end

function Highlighter.background(cached, bufnr, ns, hunk)
  local sources = cached.sources
  local _, context = comparison_sources(cached)
  local version = comparison_version(cached)
  local foreground = M.config.changed_fg
  local result = cached.background_result
  if result and result.version == version and result.foreground == foreground and result.context == context then
    return result.plan, result.loading
  end
  if not cached.background_job or cached.background_job.version ~= version or cached.background_job.foreground ~= foreground
    or cached.background_job.context ~= context then
    local job = { version = version, foreground = foreground, context = context }
    cached.background_job = job
    local function valid()
      return cached.active and cached.background_job == job and vim.api.nvim_buf_is_loaded(bufnr)
        and select(2, comparison_sources(cached)) == context
        and M.config.word_diff_style == 'treesitter'
        and M.config.changed_fg == foreground
    end
    jobs.run(function(checkpoint)
      local plan = {}
      local function emit(_, _, row, col, options)
        plan[#plan + 1] = { row = row - hunk.start_line, col = col, opts = options }
      end
      local loading = Highlighter.apply_block_word_diffs(bufnr, ns, hunk, sources, cached.layout, emit, checkpoint, context)
      return { plan = plan, loading = loading, version = version, foreground = foreground, context = context }
    end, valid, function(ready, err)
      if not valid() then return end
      cached.background_job = nil
      if not ready then error(err) end
      cached.background_result = ready
      cached.background_revision = (cached.background_revision or 0) + 1
      syntax_word_diff.request_refresh(bufnr)
    end)
  end
  -- Keep the previous spans while a new result is computed. Syntax painting
  -- proceeds independently; a partial comparison must not restart it.
  for _, mark in ipairs(cached.marks) do
    if mark.opts.priority == PRIORITY_SYNTAX + 150 or mark.opts.priority == PRIORITY_SYNTAX + 151 then
      mark.generation = cached.mark_generation
    end
  end
  return {}, true
end

function Highlighter.process_hunk(bufnr, ns, hunk, cached, query)
  cached.marks, cached.mark_map = cached.marks or {}, cached.mark_map or {}
  cached.mark_generation = (cached.mark_generation or 0) + 1
  recording[bufnr] = cached
  if cached.background_style == M.config.word_diff_style then
    for _, mark in ipairs(cached.marks) do
      local options = mark.opts
      if options.hl_group == 'FugitiveExtCode' or options.virt_text_pos == 'overlay'
        or options.hl_eol and options.priority == PRIORITY_BG then mark.generation = cached.mark_generation end
    end
  else
    Highlighter.apply_background(bufnr, ns, hunk)
    cached.background_style = M.config.word_diff_style
  end
  if not cached.layout then
    local layout = { code = { old = {}, new = {} }, colors = { old = {}, new = {} }, groups = {} }
    local inverse = { old = {}, new = {} }
    for i, line in ipairs(hunk.lines) do
      local prefix, content, relative = line:sub(1, 1), line:sub(2), i - 1
      for _, side in ipairs({ 'old', 'new' }) do
        if prefix == ' ' or prefix == (side == 'old' and '-' or '+') then
          local code = layout.code[side]
          code[#code + 1] = content
          inverse[side][relative] = #code
          if prefix ~= ' ' or side == 'new' then layout.colors[side][#code] = relative end
        end
      end
    end
    for _, change in ipairs(Utils.extract_change_groups(hunk.lines, true)) do
      local group = { rows = { old = {}, new = {} }, texts = { old = {}, new = {} }, displayed = { old = {}, new = {} } }
      for _, side in ipairs({ 'old', 'new' }) do
        for _, line in ipairs(side == 'old' and change.del_lines or change.add_lines) do
          local relative = line.idx - 1
          group.rows[side][#group.rows[side] + 1] = inverse[side][relative]
          group.texts[side][#group.texts[side] + 1] = line.text
          group.displayed[side][#group.displayed[side] + 1] = relative
        end
      end
      group.whitespace_only = table.concat(group.texts.old):match('^%s*$') and table.concat(group.texts.new):match('^%s*$')
      layout.groups[#layout.groups + 1] = group
    end
    cached.layout = layout
  end
  local code, colors = cached.layout.code, cached.layout.colors
  local prepared = Highlighter.prepare(cached, code, hunk.lang, query, bufnr)
  local plan = {}
  local loading = not prepared
  if M.config.word_diff_style == 'treesitter' then
    if prepared then plan, loading = Highlighter.background(cached, bufnr, ns, hunk) end
  elseif M.config.word_diff_style == 'diffs' then
    Highlighter.apply_diffs_style_word_diffs(bufnr, ns, hunk)
  else
    -- Delta follows forward line pairing; GitHub pairs lines sequentially.
    for _, group in ipairs(Utils.extract_change_groups(hunk.lines)) do
      local old, new, old_rows, new_rows = {}, {}, {}, {}
      for _, line in ipairs(group.del_lines) do
        old[#old + 1], old_rows[#old_rows + 1] = line.text, hunk.start_line + line.idx - 1
      end
      for _, line in ipairs(group.add_lines) do
        new[#new + 1], new_rows[#new_rows + 1] = line.text, hunk.start_line + line.idx - 1
      end
      Highlighter.apply_word_diffs(bufnr, ns, old, new, old_rows, new_rows)
    end
  end
  if M.config.word_diff_style ~= 'treesitter' or not prepared then cached.background_job = nil end
  if M.config.word_diff_style ~= 'treesitter' then cached.background_result = nil end
  if hunk.lang and prepared then
    -- Foreground painting has its own lifetime. Background comparisons often
    -- finish in several stages; they must not repeatedly cancel this job.
    Highlighter.foreground(cached, bufnr, ns, colors)
  else
    cached.foreground_job, cached.foreground_ready = nil, nil
  end
  cached.comparison_pending = loading
  local function finish_plan()
    local kept, count = 0, #cached.marks
    for i = 1, count do
      local mark = cached.marks[i]
      if mark.generation ~= cached.mark_generation then
        vim.api.nvim_buf_del_extmark(bufnr, ns, mark.id)
        cached.mark_map[mark.key] = nil
        if cached.loading_mark == mark then cached.loading_mark = nil end
      else
        kept = kept + 1
        cached.marks[kept] = mark
      end
    end
    for i = count, kept + 1, -1 do cached.marks[i] = nil end
  end
  if #plan > 256 then
    local job = {}
    cached.paint_job = job
    local function valid()
      return cached.active and cached.paint_job == job and vim.api.nvim_buf_is_loaded(bufnr)
    end
    jobs.run(function(checkpoint)
      for i, mark in ipairs(plan) do
        Highlighter.record_mark(cached, bufnr, ns, mark.row, mark.col, mark.opts)
        if i % 64 == 0 then checkpoint() end
      end
      return true
    end, valid, function(result, err)
      if not valid() then return end
      cached.paint_job = nil
      if not result then error(err) end
      finish_plan()
      Highlighter.finish_loading(cached, bufnr, ns)
    end)
  else
    for _, mark in ipairs(plan) do
      Highlighter.record_mark(cached, bufnr, ns, mark.row, mark.col, mark.opts)
    end
    -- The indicator is recorded below, so clean obsolete entries afterwards.
  end
  if M.config.word_diff_style == 'treesitter' and (loading or cached.paint_job or cached.foreground_job) then
    Highlighter.set_mark(bufnr, ns, hunk.start_line - 1, 0, {
      virt_text = { { '  ' .. spinner_frames[spinner_frame], 'Comment' } }, virt_text_pos = 'eol', priority = PRIORITY_BG,
    })
    M.start_spinner()
  end
  if not cached.paint_job then finish_plan() end
  recording[bufnr] = nil
end

-- --- Main ---

local ns = vim.api.nvim_create_namespace('fugitive_extension_syntax')
local attached_refreshers = {}
local attached_hunks = {}
local active_sources = {}
local spinner_scheduled = false

function M.start_spinner()
  if spinner_scheduled then return end
  spinner_scheduled = true
  vim.defer_fn(function()
    spinner_scheduled = false
    spinner_frame = spinner_frame % #spinner_frames + 1
    local active = false
    for bufnr, hunks in pairs(attached_hunks) do
      if vim.api.nvim_buf_is_loaded(bufnr) then
        for _, cached in pairs(hunks) do
          local mark = cached.loading_mark
          if cached.active and mark then
            mark.opts.virt_text = { { '  ' .. spinner_frames[spinner_frame], 'Comment' } }
            local options = vim.tbl_extend('force', {}, mark.opts, { id = mark.id })
            vim.api.nvim_buf_set_extmark(bufnr, ns, cached.start_line + mark.row, mark.col, options)
            active = true
          end
        end
      end
    end
    if active then M.start_spinner() end
  end, 100)
end

function M.is_pending(bufnr)
  for _, cached in pairs(attached_hunks[bufnr] or {}) do
    local sources = cached.sources or {}
    if cached.preparing or cached.paint_job or cached.foreground_job or cached.background_job
      or cached.ready_background_revision ~= (cached.background_revision or 0)
      or cached.ready_version ~= (cached.preparation_version or 0)
      or cached.version ~= comparison_version(cached) then return true end
    local compared = comparison_sources(cached)
    if compared.old and compared.old.jobs and compared.old.jobs[compared.new] then return true end
    local owner = sources.old or sources.new
    if owner then
      if owner.jobs and owner.jobs[sources.new or sources.old] then return true end
      local recovery = owner.recoveries and owner.recoveries[sources.new or sources.old]
      for _, fragments in pairs(recovery and recovery.fragments or {}) do
        if fragments.parsing then return true end
        for _, source in pairs(fragments) do
          if type(source) == 'table' and next(source.jobs or {}) then return true end
        end
      end
    end
  end
  return false
end

function M.source_is_active(bufnr, source, opposite)
  local pairs = active_sources[bufnr] and active_sources[bufnr][source]
  return pairs and (not opposite or pairs[opposite] == true)
end
local highlight_group = vim.api.nvim_create_augroup('FugitiveExtensionHighlights', { clear = true })
vim.api.nvim_create_autocmd('ColorScheme', {
  group = highlight_group,
  callback = Highlighter.setup_groups,
})

function M.refresh(bufnr)
  local refresh = attached_refreshers[bufnr]
  if not refresh then
    return false
  end
  refresh()
  return true
end

function M.refresh_all()
  local refreshed = false
  for bufnr, refresh in pairs(attached_refreshers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      refresh()
      refreshed = true
    else
      attached_refreshers[bufnr] = nil
    end
  end
  return refreshed
end

function M.cycle_word_diff_style()
  local current = M.config.word_diff_style
  local next_style = WORD_DIFF_STYLES[1]
  for i, style in ipairs(WORD_DIFF_STYLES) do
    if style == current then
      next_style = WORD_DIFF_STYLES[(i % #WORD_DIFF_STYLES) + 1]
      break
    end
  end

  M.config.word_diff_style = next_style
  M.refresh_all()
  return next_style
end

function M.toggle_changed_fg()
  M.config.changed_fg = M.config.changed_fg == 'difft' and 'syntax' or 'difft'
  M.refresh_all()
  return M.config.changed_fg
end

local function source_key(spec, hunk)
  return spec and vim.mpack.encode({ highlight_sources.key(spec), hunk.old_start, hunk.new_start }) or nil
end

function M.attach(bufnr, opts)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  if attached_refreshers[bufnr] then return end

  Highlighter.setup_groups()
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local group = vim.api.nvim_create_augroup('FugitiveExtensionSyntax' .. bufnr, { clear = true })
  local active = true
  local source_session = highlight_sources.new()

  local legacy_regions = {}
  local refresh_scheduled = false
  local hunk_cache, conflict_marks = {}, {}
  local seen_tick, seen_first_line, parsed_hunks

  local function remove_marks(marks)
    for _, mark in ipairs(marks or {}) do vim.api.nvim_buf_del_extmark(bufnr, ns, mark.id) end
  end
  local function options_at(mark, start)
    local options = vim.tbl_extend('force', {}, mark.opts)
    if options.end_row then options.end_row = options.end_row + start end
    return options
  end
  local function marks_at(marks, start, live)
    for _, mark in ipairs(marks) do
      local current = live[mark.id]
      local options = options_at(mark, start)
      if not current or current[2] ~= start + mark.row or current[3] ~= mark.col
        or options.end_col and (current[4].end_col ~= options.end_col
          or current[4].end_row ~= (options.end_row or start + mark.row)) then return false end
    end
    return true
  end

  local function refresh()
    if not active or not vim.api.nvim_buf_is_loaded(bufnr) then return end
    vim.api.nvim_buf_call(bufnr, function()
      remove_marks(conflict_marks)
      conflict_marks = {}
      local tick = vim.api.nvim_buf_get_changedtick(bufnr)
      local first_line = opts and opts.first_line and opts.first_line()
      local settings = M.config.word_diff_style .. '\0' .. (M.config.changed_fg or 'syntax') .. '\0' .. vim.o.diffopt
      local queries = {}
      local function current_query(lang)
        if not lang then return nil end
        if queries[lang] == nil then queries[lang] = vim.treesitter.query.get(lang, 'highlights') or false end
        return queries[lang] or nil
      end
      if tick == seen_tick and first_line == seen_first_line then
        local stable = true
        local languages = {}
        for _, hunk in ipairs(parsed_hunks) do
          local cached = hunk_cache[hunk.cache_key]
          local spec = hunk.lang and opts and opts.diff_source and hunk.old_start and opts.diff_source(hunk) or nil
          if cached.source_key ~= source_key(spec, hunk) then stable = false; break end
          if hunk.ft then
            if languages[hunk.ft] == nil then
              local lang = vim.treesitter.language.get_lang(hunk.ft)
              languages[hunk.ft] = lang and pcall(vim.treesitter.language.inspect, lang) and lang or false
            end
            local lang = languages[hunk.ft] or nil
            if hunk.lang ~= lang then hunk.lang, stable = lang, false end
          end
          if cached.query ~= current_query(hunk.lang) or cached.settings ~= settings
            or cached.ready_background_revision ~= (cached.background_revision or 0)
            or cached.ready_version ~= (cached.preparation_version or 0)
            or cached.version ~= comparison_version(cached) then stable = false end
        end
        if stable then
          conflict_marks = require('git.features.status_renderer').apply_conflict_highlights(bufnr, ns) or {}
          return
        end
      else
        parsed_hunks = Parser.parse_buffer(bufnr, first_line)
      end
      local live
      -- Async completions do not move buffer rows. Reading every extmark's
      -- details here dominated refreshes on long files; only edits need it.
      if seen_tick ~= nil and tick ~= seen_tick then
        live = {}
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })) do
          live[mark[1]] = mark
        end
      end
      for _, region in ipairs(legacy_regions) do
        vim.cmd('silent! syntax clear ' .. region)
      end
      legacy_regions = {}

      local hunks = parsed_hunks
      local retained, occurrences = {}, {}
      for _, hunk in ipairs(hunks) do
        local content = vim.mpack.encode({ hunk.filename or '', hunk.lang or '', hunk.ft or '', hunk.lines })
        occurrences[content] = (occurrences[content] or 0) + 1
        hunk.cache_key = content .. '\0' .. occurrences[content]
        retained[hunk.cache_key] = hunk_cache[hunk.cache_key] or {}
      end
      for key, cached in pairs(hunk_cache) do
        if not retained[key] then cached.active = false; remove_marks(cached.marks) end
      end
      local kept, sources = {}, {}
      for _, hunk in ipairs(hunks) do
        local cached = retained[hunk.cache_key]
        cached.active = true
        cached.start_line = hunk.start_line
        local spec = hunk.lang and opts and opts.diff_source and hunk.old_start and opts.diff_source(hunk) or nil
        local key = source_key(spec, hunk)
        if cached.source_key ~= key then
          cached.prepared, cached.preparing = nil, nil
          cached.source_key = key
        end
        cached.color_spec, cached.source_session = spec, source_session
        cached.source_starts = { old = hunk.old_start, new = hunk.new_start }
        local query = current_query(hunk.lang)
        local owner = cached.sources and (cached.sources.old or cached.sources.new)
        local version = comparison_version(cached)
        if cached.marks and live and not marks_at(cached.marks, hunk.start_line, live) then
          remove_marks(cached.marks)
          for _, mark in ipairs(cached.marks) do
            mark.id = vim.api.nvim_buf_set_extmark(bufnr, ns, hunk.start_line + mark.row, mark.col,
              options_at(mark, hunk.start_line))
          end
        end
        if not cached.marks or cached.query ~= query or cached.version ~= version or cached.settings ~= settings
          or cached.ready_source_key ~= key
          or cached.ready_background_revision ~= (cached.background_revision or 0)
          or cached.ready_version ~= (cached.preparation_version or 0) then
          cached.paint_job = nil
          Highlighter.process_hunk(bufnr, ns, hunk, cached, query)
          cached.query, cached.settings = query, settings
          cached.ready_source_key = key
          cached.ready_version = cached.preparation_version or 0
          cached.ready_background_revision = cached.background_revision or 0
          owner = cached.sources and (cached.sources.old or cached.sources.new)
          cached.version = comparison_version(cached)
        end
        if owner then
          sources[owner] = sources[owner] or {}
          sources[owner][cached.sources.new or cached.sources.old] = true
        end
        local compared = comparison_sources(cached)
        local full_owner = compared and (compared.old or compared.new)
        if full_owner then
          sources[full_owner] = sources[full_owner] or {}
          sources[full_owner][compared.new or compared.old] = true
        end
        if live then for _, mark in ipairs(cached.marks) do kept[mark.id] = true end end
        if not hunk.lang and hunk.ft then Highlighter.apply_legacy(bufnr, hunk, legacy_regions) end
      end
      for id in pairs(live or {}) do
        if not kept[id] then vim.api.nvim_buf_del_extmark(bufnr, ns, id) end
      end
      source_session.prune()
      hunk_cache, active_sources[bufnr] = retained, sources
      attached_hunks[bufnr] = retained
      seen_tick, seen_first_line = tick, first_line
      conflict_marks = require('git.features.status_renderer').apply_conflict_highlights(bufnr, ns) or {}
    end)
  end

  attached_refreshers[bufnr] = refresh
  refresh()

  local function schedule_refresh()
    if refresh_scheduled then return end
    refresh_scheduled = true
    vim.schedule(function()
      refresh_scheduled = false
      refresh()
    end)
  end

  vim.api.nvim_create_autocmd({'TextChanged', 'TextChangedI'}, {
    group = group,
    buffer = bufnr,
    callback = schedule_refresh,
  })

  vim.api.nvim_create_autocmd({ 'BufUnload', 'BufWipeout' }, {
    group = group,
    buffer = bufnr,
    once = true,
    callback = function()
      active = false
      source_session.close()
      attached_refreshers[bufnr] = nil
      for _, cached in pairs(hunk_cache) do cached.active = false end
      attached_hunks[bufnr] = nil
      active_sources[bufnr], hunk_cache = nil, {}
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
end

return M
