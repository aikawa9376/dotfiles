local M = {}

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
  if not ok or not result then return {} end

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

function Highlighter.apply_word_diffs(bufnr, ns, group_old, group_new, group_old_lines, group_new_lines)
  if #group_old == 0 or #group_new == 0 then return end

  -- Calculate similarity for all pairs
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

      local old_text = group_old[cand.old_idx]
      local new_text = group_new[cand.new_idx]
      local old_line_idx = group_old_lines[cand.old_idx]
      local new_line_idx = group_new_lines[cand.new_idx]

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
  end
end

function Highlighter.process_hunk(bufnr, ns, hunk)
  -- 1. Background
  Highlighter.apply_background(bufnr, ns, hunk)

  -- 2. Word Diffs & Syntax Prep
  local group_old = {}
  local group_new = {}
  local group_old_lines = {}
  local group_new_lines = {}

  local new_code = {}
  local new_map = {}
  local old_code = {}
  local old_map = {}

  local function flush_groups()
    Highlighter.apply_word_diffs(bufnr, ns, group_old, group_new, group_old_lines, group_new_lines)
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
  flush_groups()

  -- 3. Syntax Highlighting (Treesitter)
  if hunk.lang then
    Highlighter.apply_treesitter(bufnr, ns, new_code, hunk.lang, new_map, 1)
    Highlighter.apply_treesitter(bufnr, ns, old_code, hunk.lang, old_map, 1)
  end
end

-- --- Main ---

local ns = vim.api.nvim_create_namespace('fugitive_extension_syntax')

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

  refresh()

  vim.api.nvim_create_autocmd({'TextChanged', 'TextChangedI'}, {
    buffer = bufnr,
    callback = function() vim.schedule(refresh) end
  })
end

return M
