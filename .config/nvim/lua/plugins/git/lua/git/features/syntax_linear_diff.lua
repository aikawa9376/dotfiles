-- Histogram matching adapted from imara-diff 0.2.0 (Apache-2.0).
-- Local Lua adaptation; see THIRD_PARTY_NOTICES.md and licenses/imara-diff.txt.
local M = {}

-- Move ambiguous edits downward and merge adjacent modifications, matching
-- imara's postprocess_no_heuristic rather than Git's indentation heuristic.
local function postprocess(tokens, changed, opposite, opposite_len)
  local function next_change(flags, pos, length)
    for i = pos, length - 1 do if flags[i + 1] then return i - pos end end
  end
  local function finish(flags, pos)
    while flags[pos + 1] do pos = pos + 1 end
    return pos
  end
  local function start(flags, pos)
    while pos > 0 and flags[pos] do pos = pos - 1 end
    return pos
  end
  local bs, be, cs, ce = 0, 0, 0, 0
  local function up()
    if cs == 0 or tokens[cs] ~= tokens[ce] then return false end
    changed[cs], changed[ce] = true, nil
    ce, cs = ce - 1, start(changed, cs - 1)
    be, bs = bs - 1, start(opposite, bs - 1)
    return true
  end
  local function down()
    if ce == #tokens or tokens[cs + 1] ~= tokens[ce + 1] then return false end
    changed[cs + 1], changed[ce + 1] = nil, true
    cs, ce = cs + 1, finish(changed, ce)
    bs, be = be + 1, finish(opposite, be + 1)
    return true
  end
  while true do
    local offset = next_change(changed, ce, #tokens)
    if not offset then break end
    local off_before = 0
    while true do
      local unchanged = next_change(opposite, be, opposite_len) or opposite_len - be
      if off_before + unchanged > offset then bs = be + offset - off_before; be = bs; break end
      off_before = off_before + unchanged
      bs, be = be + unchanged, finish(opposite, be + unchanged)
      if off_before == offset then break end
    end
    cs, ce = ce + offset, finish(changed, ce + offset)
    local earliest, modification
    while true do
      while up() do end
      earliest, modification = ce, bs ~= be
      local size = ce - cs
      while down() do modification = modification or bs ~= be end
      if size == ce - cs then break end
    end
    if ce ~= earliest and modification then
      while bs == be do assert(up(), 'invalid linear slider alignment') end
    end
  end
end

function M.diff(left, right, key, emit, checkpoint)
  local a, b = {}, {}
  for i, item in ipairs(left) do
    a[i] = key(item)
    if checkpoint and i % 512 == 0 then checkpoint() end
  end
  for i, item in ipairs(right) do
    b[i] = key(item)
    if checkpoint and i % 512 == 0 then checkpoint() end
  end
  local removed, added = {}, {}
  local function mark(flags, first, last) for i = first, last do flags[i] = true end end
  local function fallback(al, ar, bl, br)
    local ids, serial = {}, 0
    local function encode(tokens, first, last)
      local lines = {}
      for i = first, last do
        if not ids[tokens[i]] then serial = serial + 1; ids[tokens[i]] = serial end
        lines[#lines + 1] = tostring(ids[tokens[i]])
      end
      return table.concat(lines, '\n') .. '\n'
    end
    for _, hunk in ipairs(vim.diff(encode(a, al, ar), encode(b, bl, br), {
      algorithm = 'myers', result_type = 'indices', indent_heuristic = false,
    })) do
      mark(removed, al + hunk[1] - 1, al + hunk[1] + hunk[2] - 2)
      mark(added, bl + hunk[3] - 1, bl + hunk[3] + hunk[4] - 2)
    end
  end
  local function run(al, ar, bl, br)
    if checkpoint then checkpoint() end
    if al > ar then mark(added, bl, br); return end
    if bl > br then mark(removed, al, ar); return end
    local positions = {}
    for i = al, ar do
      positions[a[i]] = positions[a[i]] or {}
      local indices = positions[a[i]]; indices[#indices + 1] = i
    end
    local minimum, length, best_a, best_b, found = 64, 0, nil, nil, false
    local j = bl
    while j <= br do
      if checkpoint and j % 512 == 0 then checkpoint() end
      local indices = positions[b[j]]
      if indices then found = true end
      if indices and #indices <= minimum then
        local next_j, index = j + 1, 1
        while indices[index] do
          local i, rarity = indices[index], #indices
          local start_a, start_b = i, j
          while start_a > al and start_b > bl and a[start_a - 1] == b[start_b - 1] do
            start_a, start_b = start_a - 1, start_b - 1
            rarity = math.min(rarity, #positions[a[start_a]])
          end
          local end_a, end_b = i + 1, j + 1
          while end_a <= ar and end_b <= br and a[end_a] == b[end_b] do
            rarity = math.min(rarity, #positions[a[end_a]])
            end_a, end_b = end_a + 1, end_b + 1
          end
          next_j = math.max(next_j, end_b)
          if length < end_b - start_b or minimum > rarity then
            minimum, length, best_a, best_b = rarity, end_b - start_b, start_a, start_b
          end
          -- Preserve the reference's occurrence selection and tie ordering.
          repeat index = index + 1 until not indices[index] or indices[index] - al > end_b - bl
        end
        j = next_j
      else j = j + 1 end
    end
    if found and minimum > 63 then fallback(al, ar, bl, br)
    elseif length == 0 then mark(removed, al, ar); mark(added, bl, br)
    else
      run(al, best_a - 1, bl, best_b - 1)
      run(best_a + length, ar, best_b + length, br)
    end
  end
  local al, ar, bl, br = 1, #a, 1, #b
  while al <= ar and bl <= br and a[al] == b[bl] do al, bl = al + 1, bl + 1 end
  while al <= ar and bl <= br and a[ar] == b[br] do ar, br = ar - 1, br - 1 end
  run(al, ar, bl, br)
  postprocess(b, added, removed, #a)
  postprocess(a, removed, added, #b)
  local i, j = 1, 1
  while i <= #left or j <= #right do
    if checkpoint and (i + j) % 512 == 0 then checkpoint() end
    if removed[i] then emit('old', left[i]); i = i + 1
    elseif added[j] then emit('new', right[j]); j = j + 1
    else emit('both', left[i], right[j]); i, j = i + 1, j + 1 end
  end
end
return M
