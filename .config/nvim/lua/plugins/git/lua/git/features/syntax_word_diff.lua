-- Structural token boundaries for local word diff. Results stay in source
-- coordinates; the view alone maps them onto unified diff rows.
local M = {}
local MAX_BYTES, MAX_TOKENS, CACHE_SIZE = 128 * 1024, 12000, 16
local cache, clock = {}, 0

function M.parse(lines, lang)
  if not lang then return nil end
  local code = table.concat(lines, '\n')
  if code == '' or #code > MAX_BYTES then return nil end
  local key = lang .. '\0' .. code
  clock = clock + 1
  if cache[key] then cache[key].used = clock; return cache[key].source end
  local ok, parser = pcall(vim.treesitter.get_string_parser, code, lang)
  if not ok or not parser then return nil end
  local parsed, trees = pcall(parser.parse, parser)
  if not parsed or not trees or not trees[1] then return nil end
  local offsets, offset = {}, 0
  for i, line in ipairs(lines) do offsets[i], offset = offset, offset + #line + 1 end
  local source = { code = code, lang = lang, lines = lines, offsets = offsets, tree = trees[1] }
  cache[key] = { source = source, used = clock }
  local count, oldest, age = 0, nil, math.huge
  for k, entry in pairs(cache) do
    count = count + 1
    if entry.used < age then oldest, age = k, entry.used end
  end
  if count > CACHE_SIZE then cache[oldest] = nil end
  return source
end

local function bounds(source, node)
  local sr, sc, er, ec = node:range()
  return source.offsets[sr + 1] + sc, source.offsets[er + 1] + ec
end

local function lexical(source, first, last, domain, tokens, trusted, unit)
  local text, cursor = source.code:sub(first + 1, last), 1
  while cursor <= #text do
    local finish = text:match('^%s+()', cursor)
    if finish then
      -- Whitespace inside a literal affects its value. Formatting outside
      -- literals (including comment reflow) does not get word emphasis.
      if domain == 'string' or domain == 'key' then
        tokens[#tokens + 1] = { first = first + cursor - 1, last = first + finish - 1,
          domain = domain, trusted = trusted, unit = unit }
      end
    else
      finish = text:match('^[%w_]+()', cursor)
      if not finish then
        local byte = text:byte(cursor)
        local length = byte >= 240 and 4 or byte >= 224 and 3 or byte >= 192 and 2 or 1
        finish = math.min(#text + 1, cursor + length)
      end
      tokens[#tokens + 1] = { first = first + cursor - 1, last = first + finish - 1,
        domain = domain, trusted = trusted, unit = unit,
        meaningful = text:sub(cursor, finish - 1):find('[%w_\128-\255]') ~= nil }
    end
    cursor = finish
  end
end

local function statement_list(node)
  local kind = node:type()
  return not node:parent() or kind == 'block' or kind == 'statement_block'
    or kind == 'class_body' or kind == 'declaration_list'
end

local function tokenize(source)
  if source.tokens ~= nil then return source.tokens or nil end
  local tokens, cursor, semantic, node_units = {}, 0, false, {}
  local function walk(node, unit)
    local first, last = bounds(source, node)
    local parent, kind = node:parent(), node:type()
    -- Statements in a body get their own correspondence checks. An expression
    -- stays together, including a callback body added to an existing call.
    if parent and node:named() and kind ~= 'ERROR' and not statement_list(node)
      and (not unit or (not unit.sealed and statement_list(parent))
        or source.lang == 'json' and kind == 'pair'
        or source.lang == 'yaml' and kind == 'block_mapping_pair'
        or source.lang == 'markdown' and kind == 'paragraph') then
      unit = { kind = kind, sealed = true }
      for child in node:iter_children() do
        if statement_list(child) then unit.sealed = false; break end
      end
    end
    node_units[node:id()] = unit
    if first > cursor then lexical(source, cursor, first, 'code', tokens, nil, unit); cursor = first end
    if node:type() == 'ERROR' then
      -- A hunk can omit the enclosing function's end while containing valid
      -- calls/literals. Recover complete child structures, using lexical
      -- boundaries for the surrounding error rather than trusting its leaves.
      for child in node:iter_children() do
        if not child:has_error() and not child:missing() and child:child_count() > 0 then walk(child, unit) end
      end
      if cursor < last then lexical(source, cursor, last, 'code', tokens, nil, unit) end
    elseif node:missing() then
      lexical(source, first, last, 'code', tokens, nil, unit)
    elseif node:type():find('comment', 1, true) then
      semantic = true
      lexical(source, first, last, 'comment', tokens, true, unit)
    elseif node:type():find('string', 1, true) or node:type() == 'block_scalar' then
      semantic = true
      local parent = node:parent()
      local key = parent and parent:field('key')[1]
      lexical(source, first, last, key and key == node and 'key' or 'string', tokens, true, unit)
    elseif node:child_count() == 0 then
      if last > first then
        semantic = true
        if node:type() == 'inline' or node:type():find('text', 1, true) then
          lexical(source, first, last, 'text', tokens, true, unit)
        else
          tokens[#tokens + 1] = { first = first, last = last, domain = 'code', trusted = true,
            normalize_space = not node:named(), meaningful = node:named(), unit = unit }
        end
      end
    else
      for child in node:iter_children() do walk(child, unit) end
    end
    cursor = last
  end
  walk(source.tree:root())
  if cursor < #source.code then lexical(source, cursor, #source.code, 'code', tokens) end
  -- In indentation-sensitive languages, statement indentation can change
  -- meaning. Argument/collection continuation indentation is still layout.
  if source.lang == 'python' or source.lang == 'yaml' then
    local seen = {}
    local function indents(node)
      local kind = node:type()
      local significant = source.lang == 'python'
        and (kind:match('_statement$') or kind:match('_definition$') or kind:match('_clause$'))
        or source.lang == 'yaml' and (kind == 'block_mapping_pair' or kind == 'block_sequence_item')
      if significant and not node:has_error() then
        local row, col = node:start()
        local prefix = source.lines[row + 1]:sub(1, col)
        if col > 0 and prefix:match('^%s+$') and not seen[row] then
          seen[row] = true
          tokens[#tokens + 1] = { first = source.offsets[row + 1],
            last = source.offsets[row + 1] + col, domain = 'indent', trusted = true,
            unit = node_units[node:id()] }
        end
      end
      for child in node:iter_children() do indents(child) end
    end
    indents(source.tree:root())
    table.sort(tokens, function(a, b) return a.first < b.first end)
  end
  -- A wholly erroneous fragment has no trustworthy structural information.
  if not semantic or #tokens > MAX_TOKENS then source.tokens = false; return nil end
  source.tokens = tokens
  return tokens
end

local function slice(source, tokens, rows)
  local first = source.offsets[rows[1]]
  local last_row = rows[#rows]
  local last = source.offsets[last_row] + #source.lines[last_row]
  local selected, trusted = {}, false
  for _, token in ipairs(tokens) do
    if token.first >= last then break end
    if token.last > first then
      local start, finish = math.max(first, token.first), math.min(last, token.last)
      local text = source.code:sub(start + 1, finish)
      if token.normalize_space then text = text:gsub('%s+', ' ') end
      selected[#selected + 1] = { first = start, last = finish,
        key = token.domain .. '\0' .. text, meaningful = token.meaningful, unit = token.unit }
      trusted = trusted or token.trusted
    end
  end
  return selected, trusted
end

local function counterpart_rows(source, tokens, rows, accepted, changed)
  local shared, row_index = {}, 1
  for i, token in ipairs(tokens) do
    if accepted[token.unit] and not changed[i] then
      while row_index < #rows and source.offsets[rows[row_index + 1]] <= token.first do
        row_index = row_index + 1
      end
      local j = row_index
      while j <= #rows and source.offsets[rows[j]] < token.last do
        local row = rows[j]
        if token.first < source.offsets[row] + #source.lines[row] then shared[row] = true end
        j = j + 1
      end
    end
  end
  return shared
end

local function spans(source, tokens, rows, accepted, changed, pure)
  local ranges = {}
  local shared = counterpart_rows(source, tokens, rows, accepted, changed)
  local row_index = 1
  for i, token in ipairs(tokens) do
    while row_index < #rows and source.offsets[rows[row_index + 1]] <= token.first do
      row_index = row_index + 1
    end
    local j = row_index
    while j <= #rows do
      local row = rows[j]
      local offset = source.offsets[row]
      if offset >= token.last then break end
      local start, finish = math.max(token.first, offset), math.min(token.last, offset + #source.lines[row])
      -- Replacements keep word emphasis even if every word on the row changes.
      -- Pure insertions/deletions need retained content on that row; otherwise
      -- this is a new/removed row, including inside an existing expression.
      if finish > start and accepted[token.unit] and changed[i] and (not pure[i] or shared[row]) then
        ranges[row] = ranges[row] or {}
        -- Same inclusive, one-based byte coordinates as Utils.merge_ranges.
        ranges[row][#ranges[row] + 1] = { start - offset + 1, finish - offset }
      end
      j = j + 1
    end
  end
  return ranges
end

local function correspondence(lhs, rhs, changes, diff)
  local function profiles(tokens)
    local units = {}
    for i, token in ipairs(tokens) do
      if token.unit then
        local unit = units[token.unit] or { tokens = {}, indices = {}, kind = token.unit.kind }
        unit.tokens[#unit.tokens + 1], unit.indices[#unit.indices + 1] = token, i
        if token.meaningful and not unit.anchor then unit.anchor = token.key end
        units[token.unit] = unit
      end
    end
    return units
  end
  local old, new, matches = profiles(lhs), profiles(rhs), {}
  local function common(i, j)
    local a, b = lhs[i], rhs[j]
    if not a.unit or not b.unit then return end
    matches[a.unit] = matches[a.unit] or {}
    local pair = matches[a.unit][b.unit] or { old = a.unit, new = b.unit, anchors = 0 }
    if a.meaningful and b.meaningful then pair.anchors = pair.anchors + 1 end
    matches[a.unit][b.unit] = pair
  end
  local i, j = 1, 1
  for _, change in ipairs(changes) do
    -- For an insertion/deletion vim.diff points to the preceding token.
    local stop = change[2] == 0 and change[1] + 1 or change[1]
    while i < stop do common(i, j); i, j = i + 1, j + 1 end
    i, j = i + change[2], j + change[4]
  end
  while i <= #lhs and j <= #rhs do common(i, j); i, j = i + 1, j + 1 end
  local candidates = {}
  for _, targets in pairs(matches) do
    for _, pair in pairs(targets) do
      local a, b = old[pair.old], new[pair.new]
      local size = math.max(#a.tokens, #b.tokens)
      -- Recompare candidate statements locally. A block-wide diff can match
      -- the old closing ')' to a later, unrelated new call's closing ')'.
      local same_shape = a.kind == b.kind and size <= 2 * math.min(#a.tokens, #b.tokens)
        and not a.kind:find('comment', 1, true) and a.kind ~= 'paragraph' and a.kind ~= 'inline'
      if pair.anchors > 0 or same_shape then
        pair.changes = diff(a.tokens, b.tokens)
      end
      local common_count = #a.tokens
      for _, change in ipairs(pair.changes or {}) do common_count = common_count - change[2] end
      local balanced = common_count / size
      local extension = common_count / math.min(#a.tokens, #b.tokens)
      -- Classify counterparts, not how much of a changed row may be colored.
      -- Retain replacements with the same expression anchor or syntax shape;
      -- unmatched statements remain ordinary additions/deletions.
      if pair.changes and (pair.anchors > 0 and (a.anchor == b.anchor or balanced >= 0.4)
        or same_shape and balanced >= 0.25) then
        pair.profiles = { old = a, new = b }
        pair.score = balanced + extension + (a.anchor and a.anchor == b.anchor and 1 or 0)
        candidates[#candidates + 1] = pair
      end
    end
  end
  table.sort(candidates, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    if a.profiles.old.indices[1] ~= b.profiles.old.indices[1] then
      return a.profiles.old.indices[1] < b.profiles.old.indices[1]
    end
    return a.profiles.new.indices[1] < b.profiles.new.indices[1]
  end)
  local accepted = { old = {}, new = {}, pairs = {} }
  for _, pair in ipairs(candidates) do
    if not accepted.old[pair.old] and not accepted.new[pair.new] then
      accepted.old[pair.old], accepted.new[pair.new] = true, true
      accepted.pairs[#accepted.pairs + 1] = pair
    end
  end
  return accepted
end

-- Compare a whole replacement group, ignoring line layout. Syntax roles stop
-- a literal's words from accidentally matching identifiers in executable code.
-- nil requests the existing local line-pairing fallback.
function M.compare(old, new, old_rows, new_rows)
  if not old or not new or #old_rows == 0 or #new_rows == 0 then return nil end
  local old_all, new_all = tokenize(old), tokenize(new)
  if not old_all or not new_all then return nil end
  local lhs, old_trusted = slice(old, old_all, old_rows)
  local rhs, new_trusted = slice(new, new_all, new_rows)
  if not old_trusted or not new_trusted then return nil end
  local ids, serial = {}, 0
  local function encode(tokens)
    local lines = {}
    for i, token in ipairs(tokens) do
      if not ids[token.key] then serial = serial + 1; ids[token.key] = tostring(serial) end
      lines[i] = ids[token.key]
    end
    -- Interned keys keep literal newlines and NULs out of vim.diff's input.
    return #lines > 0 and table.concat(lines, '\n') .. '\n' or ''
  end
  local function diff(a, b)
    local ok, changes = pcall(vim.diff, encode(a), encode(b), { result_type = 'indices', algorithm = 'histogram' })
    return ok and changes or nil
  end
  local changes = diff(lhs, rhs)
  if not changes then return nil end
  local accepted = correspondence(lhs, rhs, changes, diff)
  local changed = { old = {}, new = {} }
  local pure = { old = {}, new = {} }
  for i = 1, #lhs do changed.old[i] = true end
  for i = 1, #rhs do changed.new[i] = true end
  for _, pair in ipairs(accepted.pairs) do
    for _, side in ipairs({ 'old', 'new' }) do
      for _, i in ipairs(pair.profiles[side].indices) do changed[side][i] = nil end
    end
    for _, change in ipairs(pair.changes) do
      for i = change[1], change[1] + change[2] - 1 do
        local index = pair.profiles.old.indices[i]
        changed.old[index], pure.old[index] = true, change[4] == 0
      end
      for i = change[3], change[3] + change[4] - 1 do
        local index = pair.profiles.new.indices[i]
        changed.new[index], pure.new[index] = true, change[2] == 0
      end
    end
  end
  local result = { old = {}, new = {} }
  for _, side in ipairs({ { 'old', old, lhs, old_rows }, { 'new', new, rhs, new_rows } }) do
    for row, ranges in pairs(spans(side[2], side[3], side[4], accepted[side[1]], changed[side[1]], pure[side[1]])) do
      result[side[1]][row] = ranges
    end
  end
  return result
end

return M
