local M = {}
local syntax_word_diff = require('git.features.syntax_word_diff')
local delta_word_diff = require('git.features.delta_word_diff')

-- 'diffs':   diffs.nvim-style group diff -> line pairing -> byte diff
-- 'delta': delta 0.19.2 token alignment and forward line pairing
-- 'treesitter': structural block tokens, with delta text fallback
-- 'github':  sequential line pairing (old[i] <-> new[i])
M.config = { word_diff_style = 'delta' }

local WORD_DIFF_STYLES = { 'diffs', 'delta', 'treesitter', 'github' }

local PRIORITY_BG = 200
local PRIORITY_SYNTAX = 210

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

function Utils.extract_change_groups(hunk_lines)
  local groups = {}
  local del_buf = {}
  local add_buf = {}
  local in_del = false

  local function flush()
    if #del_buf > 0 and #add_buf > 0 then
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

function Highlighter.setup_groups()
  -- Define custom groups
  -- DiffAdd bg: #23384C, DiffDelete bg: #321e1e (approx)
  vim.api.nvim_set_hl(0, 'FugitiveExtAdd', { bg = "#23384C", default = true })
  vim.api.nvim_set_hl(0, 'FugitiveExtDelete', { bg = "#321e1e", default = true })
  vim.api.nvim_set_hl(0, 'GitStatusConflictLine', { bg = '#453e2b', default = true })

  -- Word diff highlights (intra-line)
  vim.api.nvim_set_hl(0, 'FugitiveExtAddText', { bg = "#005f5f", default = true })
  vim.api.nvim_set_hl(0, 'FugitiveExtDeleteText', { bg = "#8c3b40", default = true })
end

function Highlighter.apply_treesitter(bufnr, ns, code_lines, lang, line_map, col_offset, source)
  local code = table.concat(code_lines, '\n')
  if code == '' then return end

  local tree = source and source.tree
  if not tree then
    local ok, parser = pcall(vim.treesitter.get_string_parser, code, lang)
    if not ok or not parser then return end
    local parsed, trees = pcall(parser.parse, parser)
    if not parsed or not trees or #trees == 0 then return end
    tree = trees[1]
  end

  local query = vim.treesitter.query.get(lang, 'highlights')
  if not query then return end

  for id, node, metadata in query:iter_captures(tree:root(), code) do
    local capture_name = '@' .. query.captures[id] .. '.' .. lang
    local sr, sc, er, ec = node:range()

    -- A multiline capture must not cross inserted opposite-side rows.
    for row = sr, er do
      local buf_row = line_map[row + 1]
      local first = row == sr and sc or 0
      local last = row == er and ec or #(code_lines[row + 1] or '')
      local priority = (tonumber(metadata.priority) or 100) + PRIORITY_SYNTAX
      if buf_row and last > first then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, buf_row, first + col_offset, {
          end_col = last + col_offset,
          hl_group = capture_name,
          priority = priority,
        })
      end
    end
  end
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
    vim.cmd(string.format('silent! syntax include @%s syntax/%s.vim', ft_group, hunk.ft))
    vim.api.nvim_buf_set_var(bufnr, included_var, true)
  end

  -- The header's one-based row precedes the code body; include the final EOL.
  local start_row = hunk.start_line + 1
  local last_line = hunk.start_line + #hunk.lines
  local region_name = 'FugitiveExtRegion_' .. start_row

  vim.cmd(string.format('syntax region %s start=/\\%%%dl/ end=/\\%%%dl$/ contains=@%s keepend', region_name, start_row, last_line, ft_group))
  table.insert(regions, region_name)
end

function Highlighter.apply_background(bufnr, ns, hunk)
  for i, line in ipairs(hunk.lines) do
    local prefix = line:sub(1, 1)
    local buf_line = hunk.start_line + i - 1

    if prefix == '+' or prefix == '-' then
      local hl_group = (prefix == '+') and 'FugitiveExtAdd' or 'FugitiveExtDelete'
      local prefix_hl = (prefix == '+') and 'FugitiveExtAddPrefix' or 'FugitiveExtDeletePrefix'

      -- Background highlight
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, buf_line, 0, {
        end_row = buf_line + 1,
        end_col = 0,
        hl_group = hl_group,
        hl_eol = true,
        priority = PRIORITY_BG,
        strict = false,
      })

      -- Hide prefix
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, buf_line, 0, {
        virt_text = { { ' ', prefix_hl } },
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
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, buf_line, span.col_start, {
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
        vim.api.nvim_buf_set_extmark(bufnr, ns, side[2][row], range[1], {
          end_col = range[2] + 1, hl_group = side[3], priority = PRIORITY_SYNTAX + 150,
        })
      end
    end
  end
end

function Highlighter.apply_block_word_diffs(bufnr, ns, hunk, sources, row_maps, inverse_maps)
  for _, group in ipairs(Utils.extract_change_groups(hunk.lines)) do
    local rows, texts, displayed = { old = {}, new = {} }, { old = {}, new = {} }, { old = {}, new = {} }
    for _, side in ipairs({ 'old', 'new' }) do
      for _, line in ipairs(side == 'old' and group.del_lines or group.add_lines) do
        local buf_row = hunk.start_line + line.idx - 1
        rows[side][#rows[side] + 1] = inverse_maps[side][buf_row]
        texts[side][#texts[side] + 1] = line.text
        displayed[side][#displayed[side] + 1] = buf_row
      end
    end
    local changes = syntax_word_diff.compare(sources.old, sources.new, rows.old, rows.new)
    if hunk.lang and table.concat(texts.old):match('^%s*$') and table.concat(texts.new):match('^%s*$') then
      changes = { old = {}, new = {} }
    end
    if not changes then
      Highlighter.apply_word_diffs(bufnr, ns, texts.old, texts.new, displayed.old, displayed.new)
    else
      for _, side in ipairs({ 'old', 'new' }) do
        for row, ranges in pairs(changes[side]) do
          for _, range in ipairs(Utils.merge_ranges(ranges, sources[side].lines[row])) do
            vim.api.nvim_buf_set_extmark(bufnr, ns, row_maps[side][row], range[1], {
              end_col = range[2] + 1,
              hl_group = side == 'old' and 'FugitiveExtDeleteText' or 'FugitiveExtAddText',
              priority = PRIORITY_SYNTAX + 150,
            })
          end
        end
      end
    end
  end
end

function Highlighter.process_hunk(bufnr, ns, hunk)
  Highlighter.apply_background(bufnr, ns, hunk)
  local code, maps, inverse = { old = {}, new = {} }, { old = {}, new = {} }, { old = {}, new = {} }
  local colors = { old = {}, new = {} }
  for i, line in ipairs(hunk.lines) do
    local prefix, content, buf_row = line:sub(1, 1), line:sub(2), hunk.start_line + i - 1
    for _, side in ipairs({ 'old', 'new' }) do
      if prefix == ' ' or prefix == (side == 'old' and '-' or '+') then
        table.insert(code[side], content)
        maps[side][#code[side]] = buf_row
        inverse[side][buf_row] = #code[side]
        -- Shared context is displayed with the new source's syntax only.
        if prefix ~= ' ' or side == 'new' then colors[side][#code[side]] = buf_row end
      end
    end
  end
  local sources = {}
  if M.config.word_diff_style == 'treesitter' then
    for _, side in ipairs({ 'old', 'new' }) do sources[side] = syntax_word_diff.parse(code[side], hunk.lang) end
    Highlighter.apply_block_word_diffs(bufnr, ns, hunk, sources, maps, inverse)
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
  if hunk.lang then
    for _, side in ipairs({ 'old', 'new' }) do
      Highlighter.apply_treesitter(bufnr, ns, code[side], hunk.lang, colors[side], 1, sources[side])
    end
  end
end

-- --- Main ---

local ns = vim.api.nvim_create_namespace('fugitive_extension_syntax')
local attached_refreshers = {}
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

function M.attach(bufnr, opts)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  if attached_refreshers[bufnr] then return end

  Highlighter.setup_groups()
  local group = vim.api.nvim_create_augroup('FugitiveExtensionSyntax' .. bufnr, { clear = true })
  local active = true

  local legacy_regions = {}
  local refresh_scheduled = false

  local function refresh()
    if not active or not vim.api.nvim_buf_is_loaded(bufnr) then return end
    vim.api.nvim_buf_call(bufnr, function()
      vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

      for _, region in ipairs(legacy_regions) do
        vim.cmd('silent! syntax clear ' .. region)
      end
      legacy_regions = {}

      local hunks = Parser.parse_buffer(bufnr, opts and opts.first_line and opts.first_line())
      for _, hunk in ipairs(hunks) do
        Highlighter.process_hunk(bufnr, ns, hunk)
        if not hunk.lang and hunk.ft then
          Highlighter.apply_legacy(bufnr, hunk, legacy_regions)
        end
      end
      require('git.features.status_renderer').apply_conflict_highlights(bufnr, ns)
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
      attached_refreshers[bufnr] = nil
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
end

return M
