local M = {}

-- 'diffs':   diffs.nvim-style group diff -> line pairing -> byte diff
-- 'lazygit': similarity-based line pairing
-- 'github':  sequential line pairing (old[i] <-> new[i])
M.config = { word_diff_style = 'diffs' }

local WORD_DIFF_STYLES = { 'diffs', 'lazygit', 'github' }

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

function Utils.levenshtein(str1, str2)
  local len1 = #str1
  local len2 = #str2
  local matrix = {}

  if (len1 == 0) then return len2 end
  if (len2 == 0) then return len1 end
  if (str1 == str2) then return 0 end

  for i = 0, len1 do
    matrix[i] = {[0] = i}
  end

  for j = 0, len2 do
    matrix[0][j] = j
  end

  for i = 1, len1 do
    for j = 1, len2 do
      local cost = (str1:byte(i) == str2:byte(j)) and 0 or 1
      matrix[i][j] = math.min(matrix[i - 1][j] + 1, matrix[i][j - 1] + 1, matrix[i - 1][j - 1] + cost)
    end
  end

  return matrix[len1][len2]
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

function Utils.trim(s)
  return s:match("^%s*(.-)%s*$") or ""
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
    for key, value in pairs(diff_opts) do
      if value ~= nil then
        vim_opts[key] = value
      end
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

function Parser.parse_buffer(bufnr)
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

  for i, line in ipairs(lines) do
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
      if prefix == ' ' or prefix == '+' or prefix == '-' then
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

  -- Word diff highlights (intra-line)
  vim.api.nvim_set_hl(0, 'FugitiveExtAddText', { bg = "#005f5f", default = true })
  vim.api.nvim_set_hl(0, 'FugitiveExtDeleteText', { bg = "#8c3b40", default = true })
end

function Highlighter.apply_treesitter(bufnr, ns, code_lines, lang, line_map, col_offset)
  local code = table.concat(code_lines, '\n')
  if code == '' then return end

  local ok, parser = pcall(vim.treesitter.get_string_parser, code, lang)
  if not ok or not parser then return end

  local trees = parser:parse()
  if not trees or #trees == 0 then return end

  local query = vim.treesitter.query.get(lang, 'highlights')
  if not query then return end

  for id, node, metadata in query:iter_captures(trees[1]:root(), code) do
    local capture_name = '@' .. query.captures[id] .. '.' .. lang
    local sr, sc, er, ec = node:range()

    local buf_sr = line_map[sr + 1]
    if buf_sr then
      local buf_er = line_map[er + 1] or buf_sr
      local buf_sc = sc + col_offset
      local buf_ec = ec + col_offset
      local priority = (tonumber(metadata.priority) or 100) + PRIORITY_SYNTAX

      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, buf_sr, buf_sc, {
        end_row = buf_er,
        end_col = buf_ec,
        hl_group = capture_name,
        priority = priority,
      })
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

  local start_row = hunk.start_line
  local last_line = start_row + #hunk.lines - 1
  local region_name = 'FugitiveExtRegion_' .. start_row

  vim.cmd(string.format('syntax region %s start=/\\%%%dl/ end=/\\%%%dl/ contains=@%s keepend', region_name, start_row, last_line, ft_group))
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

  local function apply_span(span, hl_group)
    local line = hunk.lines[span.line]
    if not line then
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

  -- Apply word-level highlights for a matched old/new line pair
  local function highlight_pair(old_text, new_text, old_line_idx, new_line_idx)
    local diffs = Utils.compute_word_diffs(old_text, new_text)
    local old_highlights = {}
    local new_highlights = {}

    for _, d in ipairs(diffs) do
      if d[1] then table.insert(old_highlights, { d[1], d[2] }) end
      if d[3] then table.insert(new_highlights, { d[3], d[4] }) end
    end

    old_highlights = Utils.merge_ranges(old_highlights, old_text)
    new_highlights = Utils.merge_ranges(new_highlights, new_text)

    for _, r in ipairs(old_highlights) do
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, old_line_idx, r[1], {
        end_col = r[2] + 1,
        hl_group = 'FugitiveExtDeleteText',
        priority = PRIORITY_SYNTAX + 150
      })
    end

    for _, r in ipairs(new_highlights) do
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, new_line_idx, r[1], {
        end_col = r[2] + 1,
        hl_group = 'FugitiveExtAddText',
        priority = PRIORITY_SYNTAX + 150
      })
    end
  end

  -- GitHub style: sequential pairing (old[i] <-> new[i])
  if M.config.word_diff_style == 'github' then
    for i = 1, math.min(#group_old, #group_new) do
      highlight_pair(group_old[i], group_new[i], group_old_lines[i], group_new_lines[i])
    end
    return
  end

  -- Lazygit style: similarity-based pairing (default)
  local candidates = {}
  local MAX_INDEX_DIST = 4

  for i, old_text in ipairs(group_old) do
    local old_trim = Utils.trim(old_text)
    for j, new_text in ipairs(group_new) do
       if math.abs(i - j) <= MAX_INDEX_DIST then
         local new_trim = Utils.trim(new_text)

         local dist_trim = Utils.levenshtein(old_trim, new_trim)
         local max_trim_len = math.max(#old_trim, #new_trim)
         local min_trim_len = math.min(#old_trim, #new_trim)
         local prefix_trim_len = Utils.common_prefix_len(old_trim, new_trim)

         local ratio_trim = 1.0
         if max_trim_len > 0 then
           ratio_trim = dist_trim / max_trim_len
         elseif #old_trim == 0 and #new_trim == 0 then
           ratio_trim = 0
         end

         local is_content_prefix_match = (min_trim_len > 1) and ((prefix_trim_len / min_trim_len) > 0.7)

         if ratio_trim <= 0.6 or is_content_prefix_match then
           local prefix_ratio = (max_trim_len > 0) and (prefix_trim_len / max_trim_len) or 0
           local score = ratio_trim + (math.abs(i - j) * 0.01) - (prefix_ratio * 0.2)

           if is_content_prefix_match then score = score - 0.5 end
           if old_trim == new_trim and #old_trim > 0 then score = score - 1.0 end

           table.insert(candidates, { old_idx = i, new_idx = j, ratio = ratio_trim, score = score })
         end
       end
    end
  end

  table.sort(candidates, function(a, b) return a.score < b.score end)

  local used_old = {}
  local used_new = {}

  for _, cand in ipairs(candidates) do
    if not used_old[cand.old_idx] and not used_new[cand.new_idx] then
      used_old[cand.old_idx] = true
      used_new[cand.new_idx] = true
      highlight_pair(
        group_old[cand.old_idx], group_new[cand.new_idx],
        group_old_lines[cand.old_idx], group_new_lines[cand.new_idx]
      )
    end
  end
end

function Highlighter.process_hunk(bufnr, ns, hunk)
  -- 1. Background
  Highlighter.apply_background(bufnr, ns, hunk)

  -- 2. Word Diffs & Syntax Prep
  local word_style = M.config.word_diff_style
  if word_style == 'diffs' then
    Highlighter.apply_diffs_style_word_diffs(bufnr, ns, hunk)
  end

  local group_old = {}
  local group_new = {}
  local group_old_lines = {}
  local group_new_lines = {}

  local new_code = {}
  local new_map = {}
  local old_code = {}
  local old_map = {}

  local function flush_groups()
    if word_style ~= 'diffs' then
      Highlighter.apply_word_diffs(bufnr, ns, group_old, group_new, group_old_lines, group_new_lines)
    end
    group_old = {}
    group_new = {}
    group_old_lines = {}
    group_new_lines = {}
  end

  for i, line in ipairs(hunk.lines) do
    local prefix = line:sub(1, 1)
    local content = line:sub(2)
    local buf_line = hunk.start_line + i - 1

    -- Collect code for syntax highlighting
    if prefix == '+' or prefix == ' ' then
      table.insert(new_code, content)
      new_map[#new_code] = buf_line
    end
    if prefix == '-' or prefix == ' ' then
      table.insert(old_code, content)
      old_map[#old_code] = buf_line
    end

    -- Collect groups for word diff
    if word_style ~= 'diffs' then
      if prefix == '-' then
        if #group_new > 0 then flush_groups() end
        table.insert(group_old, content)
        table.insert(group_old_lines, buf_line)
      elseif prefix == '+' then
        table.insert(group_new, content)
        table.insert(group_new_lines, buf_line)
      else
        flush_groups()
      end
    end
  end
  flush_groups()

  -- 3. Syntax Highlighting (Treesitter)
  if hunk.lang then
    Highlighter.apply_treesitter(bufnr, ns, new_code, hunk.lang, new_map, 1)
    Highlighter.apply_treesitter(bufnr, ns, old_code, hunk.lang, old_map, 1)
  end
end

-- --- Main ---

local ns = vim.api.nvim_create_namespace('fugitive_extension_syntax')
local attached_refreshers = {}

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

function M.attach(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  Highlighter.setup_groups()
  vim.api.nvim_create_autocmd('ColorScheme', { callback = Highlighter.setup_groups })

  local legacy_regions = {}

  local function refresh()
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

    for _, region in ipairs(legacy_regions) do
      vim.cmd('silent! syntax clear ' .. region)
    end
    legacy_regions = {}

    local hunks = Parser.parse_buffer(bufnr)
    for _, hunk in ipairs(hunks) do
      Highlighter.process_hunk(bufnr, ns, hunk)
      if not hunk.lang and hunk.ft then
        Highlighter.apply_legacy(bufnr, hunk, legacy_regions)
      end
    end
  end

  attached_refreshers[bufnr] = refresh
  refresh()

  vim.api.nvim_create_autocmd({'TextChanged', 'TextChangedI'}, {
    buffer = bufnr,
    callback = function() vim.schedule(refresh) end
  })

  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = bufnr,
    once = true,
    callback = function()
      attached_refreshers[bufnr] = nil
    end,
  })
end

return M
