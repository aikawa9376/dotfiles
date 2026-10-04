-- Delta 0.19.2 default within-line comparison, in source byte coordinates.
-- Adapted from src/align.rs and src/edits.rs; see THIRD_PARTY_NOTICES.md.
local M = {}
local ffi = require('ffi')
local unicode = require('git.features.delta_unicode')
local cache, clock = {}, 0
local NOOP, DELETE, INSERT = 0, 1, 2

local function category(cp, ranges)
  local lo, hi = 1, #ranges
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local range = ranges[mid]
    if cp < range[1] then hi = mid - 1
    elseif cp > range[2] then lo = mid + 1
    else return range[3] or true end
  end
  return false
end

local function scalar(text, offset)
  local b = text:byte(offset)
  if b < 128 then return b, offset + 1 end
  local n = b < 224 and 2 or b < 240 and 3 or 4
  local cp = b % (2 ^ (7 - n))
  for i = 1, n - 1 do cp = cp * 64 + (text:byte(offset + i) or 0) % 64 end
  return cp, offset + n
end

local function is_word(cp)
  if cp < 128 then return cp >= 48 and cp <= 57 or cp >= 65 and cp <= 90
    or cp == 95 or cp >= 97 and cp <= 122 end
  return category(cp, unicode.word)
end

local function grapheme(cp)
  if cp >= 0xAC00 and cp <= 0xD7A3 then return (cp - 0xAC00) % 28 == 0 and 8 or 9 end
  return category(cp, unicode.grapheme) or 0
end

local function boundary(a, b, regional)
  if a == 1 and b == 7 then return false end -- CR LF
  if a == 1 or a == 2 or a == 7 or b == 1 or b == 2 or b == 7 then return true end
  if a == 6 and (b == 6 or b == 14 or b == 8 or b == 9) then return false end
  if (a == 8 or a == 14) and (b == 14 or b == 13) then return false end
  if (a == 9 or a == 13) and b == 13 then return false end
  if b == 3 or b == 15 or b == 12 or a == 10 then return false end
  if a == 11 and b == 11 then return regional % 2 == 0 end
  return true
end

local function whitespace(cp)
  return cp >= 9 and cp <= 13 or cp == 32 or cp == 0x85 or cp == 0xA0 or cp == 0x1680
    or cp >= 0x2000 and cp <= 0x200A or cp == 0x2028 or cp == 0x2029
    or cp == 0x202F or cp == 0x205F or cp == 0x3000
end

local function trim(text)
  if not text:find('[\128-\255]') then return text:match('^%s*(.-)%s*$') end
  local first, last, offset = nil, 0, 1
  while offset <= #text do
    local cp, finish = scalar(text, offset)
    if not whitespace(cp) then first, last = first or offset, finish - 1 end
    offset = finish
  end
  return first and text:sub(first, last) or ''
end

local function prepare(text)
  -- Delta strips the terminal CR before comparing a CRLF patch line.
  text = text:gsub('\r$', '')
  local expanded, map = {}, {}
  for i = 1, #text do
    local part = text:sub(i, i) == '\t' and string.rep(' ', 8) or text:sub(i, i)
    expanded[#expanded + 1] = part
    for _ = 1, #part do map[#map + 1] = i end
  end
  local code = table.concat(expanded) .. '\n'
  local tokens = { { text = '', first = 1, last = 0 } }
  local offset, prev_word, prev_cat, regional = 1, false, nil, 0
  while offset <= #code do
    local cp, finish = scalar(code, offset)
    local word = is_word(cp)
    local cat = not word and grapheme(cp) or 0
    if offset == 1 and not word then tokens[#tokens + 1] = { text = '', first = 1, last = 0 } end
    local previous = tokens[#tokens]
    local join = word and prev_word or not word and not prev_word and prev_cat
      and not boundary(prev_cat, cat, regional)
    if join then
      previous.last = finish - 1
      previous.text = code:sub(previous.first, previous.last)
    else
      tokens[#tokens + 1] = { text = code:sub(offset, finish - 1), first = offset, last = finish - 1 }
    end
    regional = cat == 11 and (prev_cat == 11 and regional + 1 or 1) or 0
    prev_word, prev_cat, offset = word, not word and cat or nil, finish
  end
  return { code = code, tokens = tokens, map = map }
end

local function operations(x, y)
  local stride = #x + 1
  local ops = ffi.new('uint8_t[?]', stride * (#y + 1))
  local prev, current = ffi.new('uint32_t[?]', stride), ffi.new('uint32_t[?]', stride)
  for i = 1, #x do prev[i], ops[i] = 2 * i + 1, DELETE end
  for j = 1, #y do
    local row, up = j * stride, (j - 1) * stride
    current[0], ops[row] = 2 * j + 1, INSERT
    for i = 1, #x do
      local op = INSERT
      local cost = prev[i] + 2 + (ops[up + i] == NOOP and 1 or 0)
      local deletion = current[i - 1] + 2 + (ops[row + i - 1] == NOOP and 1 or 0)
      if deletion < cost then cost, op = deletion, DELETE end
      if x[i].text == y[j].text and prev[i - 1] < cost then cost, op = prev[i - 1], NOOP end
      current[i], ops[row + i] = cost, op
    end
    prev, current = current, prev
  end
  local reversed, i, j = {}, #x, #y
  repeat
    local op = tonumber(ops[j * stride + i])
    reversed[#reversed + 1] = op
    if i == 0 or j == 0 then break end
    if op ~= INSERT then i = i - 1 end
    if op ~= DELETE then j = j - 1 end
  until i == 0 and j == 0
  local runs = {}
  for k = #reversed, 1, -1 do
    local op, last = reversed[k], runs[#runs]
    if last and last[1] == op then last[2] = last[2] + 1
    else runs[#runs + 1] = { op, 1 } end
  end
  return runs
end

local function range(ranges, source, first, last)
  first, last = source.map[first], source.map[math.min(last, #source.map)]
  if not first or not last or last < first then return end
  local previous = ranges[#ranges]
  if previous and first <= previous[2] + 1 then previous[2] = math.max(previous[2], last)
  else ranges[#ranges + 1] = { first, last } end
end

local function annotate(old, new)
  local x, y = old.tokens, new.tokens
  local result = { old = {}, new = {} }
  local xi, yi, numerator, denominator, old_changed, new_changed = 1, 1, 0, 0, false, false
  local function section(source, tokens, first, n)
    local start, finish = tokens[first].first, tokens[first + n - 1].last
    local text = source.code:sub(start, finish)
    local content = trim(text)
    -- A leading combining mark/joiner has zero width in unicode-width. The
    -- dummy space prevents Neovim from displaying it as a standalone escape.
    local width = content == '' and 0 or vim.fn.strdisplaywidth(' ' .. content) - 1
    return start, finish, width, content == ''
  end
  for _, run in ipairs(operations(x, y)) do
    local op, n = run[1], run[2]
    if op == DELETE then
      local first, last, width = section(old, x, xi, n)
      numerator, denominator, xi = numerator + width, denominator + width, xi + n
      range(result.old, old, first, last)
      old_changed = true
    elseif op == INSERT then
      local first, last, width = section(new, y, yi, n)
      numerator, denominator, yi = numerator + width, denominator + width, yi + n
      range(result.new, new, first, last)
      new_changed = true
    else
      local first, last, width, space = section(old, x, xi, n)
      xi, denominator = xi + n, denominator + 2 * width
      local bridge = space and old_changed and new_changed and (xi < #x or yi < #y)
      if bridge then range(result.old, old, first, last) end
      first, last = section(new, y, yi, n)
      if bridge then range(result.new, new, first, last) end
      yi, old_changed, new_changed = yi + n, false, false
    end
  end
  return result, denominator > 0 and numerator / denominator or 0
end

function M.compare(old_lines, new_lines)
  local key = vim.mpack.encode({ old_lines, new_lines })
  clock = clock + 1
  if cache[key] then cache[key].used = clock; return cache[key].result end
  local result, old, new = { old = {}, new = {} }, {}, {}
  local function flush()
    if #old > 0 and #new > 0 then
      local plus = 1
      local prepared_new = {}
      for _, minus in ipairs(old) do
        local before = prepare(minus.text)
        for j = plus, #new do
          prepared_new[j] = prepared_new[j] or prepare(new[j].text)
          local changes, distance = annotate(before, prepared_new[j])
          if distance <= 0.6 then
            -- Delta's whitespace-error style replaces emph-only trailing
            -- whitespace sections on additions. It is not a word accent.
            for k = #changes.new, 1, -1 do
              if trim(new[j].text:sub(changes.new[k][1])) == '' then table.remove(changes.new, k)
              else break end
            end
            result.old[minus.row], result.new[new[j].row] = changes.old, changes.new
            plus = j + 1
            break
          end
        end
      end
    end
    old, new = {}, {}
  end
  -- Delta flushes before the next input line once either buffer exceeds 32.
  -- This matters for long replacement groups, including exactly 33 deletions.
  for _, side in ipairs({ { old_lines, 'old' }, { new_lines, 'new' } }) do
    for row, text in ipairs(side[1]) do
      if #old > 32 or #new > 32 then flush() end
      local buffer = side[2] == 'old' and old or new
      buffer[#buffer + 1] = { row = row, text = text }
    end
  end
  flush()
  if #key <= 256 * 1024 then
    cache[key] = { used = clock, result = result }
    local count, oldest, age = 0, nil, math.huge
    for k, entry in pairs(cache) do
      count = count + 1
      if entry.used < age then oldest, age = k, entry.used end
    end
    if count > 32 then cache[oldest] = nil end
  end
  return result
end

return M
