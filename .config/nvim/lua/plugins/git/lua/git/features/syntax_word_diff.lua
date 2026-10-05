-- Local structural diff adapted from Difftastic 0.71.0 (MIT; see
-- THIRD_PARTY_NOTICES.md). Atoms and paired delimiters are compared by a
-- shortest path, retaining source coordinates for unified-view projection.
local M = {}
local jobs = require('git.features.highlight_jobs')
local MAX_BYTES, MAX_NODES, MAX_GRAPH, CACHE_SIZE = 1000000, 3000000, 3000000, 16
local cache, clock = {}, 0
local parsing = {}
local ready_buffers = {}

-- Difftastic treats Markdown as Text. Its block grammar also leaves prose
-- gaps between children (notably fenced content), so it is not a token tree.
local function structural_language(lang)
  return lang ~= 'markdown' and lang ~= 'markdown_inline'
end

function M.version(old, new)
  local owner = old or new
  return owner and owner.versions and owner.versions[new or old] or 0
end

local function refresh_when_ready(bufnr)
  if ready_buffers[bufnr] then return end
  ready_buffers[bufnr] = true
  vim.defer_fn(function()
    ready_buffers[bufnr] = nil
    require('git.features.syntax_highlight').refresh(bufnr)
  end, 16)
end
M.request_refresh = refresh_when_ready

local function remember(key, source)
  cache[key] = { source = source, used = clock }
  local count, oldest, age = 0, nil, math.huge
  for k, entry in pairs(cache) do
    count = count + 1
    if entry.used < age then oldest, age = k, entry.used end
  end
  if count > CACHE_SIZE then cache[oldest] = nil end
end

local function source_tree(lines, code, lang, tree)
  local offsets, offset = {}, 0
  for i, line in ipairs(lines) do offsets[i], offset = offset, offset + #line + 1 end
  return { code = code, lang = lang, lines = lines, offsets = offsets, tree = tree }
end

function M.parse(lines, lang, cache_parse)
  if not lang then return nil end
  local code = table.concat(lines, '\n')
  if #code > MAX_BYTES then return nil end
  local key = cache_parse ~= false and lang .. '\0' .. code or nil
  clock = clock + 1
  if key and cache[key] then cache[key].used = clock; return cache[key].source end
  local ok, parser = pcall(vim.treesitter.get_string_parser, code, lang)
  if not ok or not parser then return nil end
  local parsed, trees = pcall(parser.parse, parser)
  if not parsed or not trees or not trees[1] then return nil end
  local source = source_tree(lines, code, lang, trees[1])
  if not key then return source end
  remember(key, source)
  return source
end

-- UI preparation uses Neovim's asynchronous (3 ms sliced) parser API. Share
-- pending sources as well as completed trees; closed hunks receive no result.
function M.parse_async(lines, lang, valid, callback, cancelled)
  if not lang then callback(nil); return end
  local code = table.concat(lines, '\n')
  if #code > MAX_BYTES then callback(nil); return end
  local key = lang .. '\0' .. code
  clock = clock + 1
  if cache[key] then cache[key].used = clock; callback(cache[key].source); return end
  local listener = { valid = valid, callback = callback, cancelled = cancelled }
  if parsing[key] then parsing[key][#parsing[key] + 1] = listener; return end
  local listeners = { listener }
  parsing[key] = listeners
  jobs.schedule(function()
    local function live()
      for _, item in ipairs(listeners) do if not item.valid or item.valid() then return true end end
      return false
    end
    local finished = false
    local function done(err, trees)
      if finished then return end
      finished = true
      parsing[key] = nil
      if not live() then
        for _, item in ipairs(listeners) do if item.cancelled then item.cancelled() end end
        return
      end
      local source = not err and trees and trees[1] and source_tree(lines, code, lang, trees[1]) or nil
      if source then
        clock = clock + 1
        -- A synchronous oracle/user request may have filled the same cache
        -- while parsing was pending. Keep one source identity for all waiters.
        if cache[key] then source = cache[key].source else remember(key, source) end
      end
      for _, item in ipairs(listeners) do
        if not item.valid or item.valid() then item.callback(source)
        elseif item.cancelled then item.cancelled() end
      end
    end
    if not live() then done('cancelled'); return end
    local ok, parser = pcall(vim.treesitter.get_string_parser, code, lang)
    if not ok or not parser then done('parser unavailable'); return end
    local success, trees = pcall(parser.parse, parser, nil, done)
    if not success then done(trees) elseif trees then done(nil, trees) end
  end)
end

local function bounds(source, node)
  local sr, sc, er, ec = node:range()
  return (source.offsets[sr + 1] or #source.code) + sc, (source.offsets[er + 1] or #source.code) + ec
end
-- Grammar rules mirror the reference's atom/delimiter conversion. Other
-- grammars use conservative string/comment detection and the common pairs.
local rules = {
  lua = { atoms = { 'string' } },
  json = { atoms = { 'string' }, delims = { { '{', '}' }, { '[', ']' } } },
  javascript = { atoms = { 'string', 'template_string', 'regex' }, angle = true,
    trailing = { 'object', 'object_pattern', 'array', 'array_pattern', 'arguments', 'formal_parameters', 'named_imports' } },
  python = { atoms = { 'string' }, trailing = { 'dictionary', 'list', 'set', 'argument_list', 'parameters' } },
  php = { atoms = { 'string', 'encapsed_string' }, text_atoms = { 'text' } },
  yaml = { atoms = { 'string_scalar', 'double_quote_scalar', 'single_quote_scalar', 'block_scalar' } },
  bash = { atoms = { 'string', 'raw_string', 'heredoc_body', 'simple_expansion' } },
  c = { atoms = { 'string_literal', 'char_literal' } },
  cpp = { atoms = { 'string_literal', 'char_literal', 'raw_string_literal' }, angle = true },
  go = { atoms = { 'interpreted_string_literal', 'raw_string_literal' } },
  rust = { atoms = { 'char_literal', 'string_literal', 'raw_string_literal' } },
  toml = { atoms = { 'string', 'quoted_key' } },
  markdown = { atoms = { 'inline' } },
}
rules.typescript = vim.deepcopy(rules.javascript)
rules.typescript.atoms[#rules.typescript.atoms + 1] = 'predefined_type'
rules.tsx = rules.typescript
local common_delims = { { '(', ')' }, { '{', '}' }, { '[', ']' } }

local function syntax_tree(source, checkpoint)
  if source.syntax ~= nil then return source.syntax or nil end
  -- Incomplete Git hunks can still be syntax-colored, but an erroneous tree
  -- cannot promise structural correspondence. Match the reference fallback.
  if source.tree:root():has_error() then source.syntax = false; return nil end
  local rule, count = rules[source.lang] or {}, 0
  local delims = vim.deepcopy(rule.delims or common_delims)
  if rule.angle then delims[#delims + 1] = { '<', '>' } end
  local function list(children, open, close)
    if #children == 1 and not open then return children[1] end
    return { children = children, open = open, close = close }
  end
  local function stamp(part, node)
    if part and source.lang == 'python' and node:type():match('_statement$') then
      local row, col = node:start()
      if (source.lines[row + 1] or ''):sub(1, col):match('^%s*$') then part.statement_indent = col end
    end
    return part
  end
  local function convert(node)
    count = count + 1
    if checkpoint and count % 256 == 0 then checkpoint() end
    if count > MAX_NODES then return nil end
    local first, last = bounds(source, node)
    local kind, text = node:type(), source.code:sub(first + 1, last)
    if text == '' or kind == '\n' then return nil end
    local comment = kind:find('comment', 1, true) ~= nil
    local text_atom = vim.list_contains(rule.text_atoms or {}, kind)
    local atom = text_atom or vim.list_contains(rule.atoms or {}, kind)
      or not rules[source.lang] and (kind:find('string', 1, true) or kind:find('scalar', 1, true))
    if atom or comment or node:child_count() == 0 then
      if text:sub(-1) == '\n' then text, last = text:sub(1, -2), last - 1 end
      return { first = first, last = last, text = text,
        kind = comment and 'comment' or atom and ((text_atom or source.lang == 'markdown') and 'text' or 'string') or 'normal' }
    end
    local nodes, opening, closing = {}, nil, nil
    for child in node:iter_children() do nodes[#nodes + 1] = child end
    for i, child in ipairs(nodes) do
      if child:child_count() == 0 then
        local a, b = bounds(source, child)
        local token = source.code:sub(a + 1, b)
        for _, pair in ipairs(delims) do
          if token == pair[1] then
            for j = i + 1, #nodes do
              local c, d = bounds(source, nodes[j])
              if nodes[j]:child_count() == 0 and source.code:sub(c + 1, d) == pair[2] then
                opening, closing = i, j; break
              end
            end
          end
          if opening then break end
        end
      end
      if opening then break end
    end
    local before, inner, after, open, close = {}, {}, {}
    for i, child in ipairs(nodes) do
      local part = convert(child)
      if opening and i == opening then open = part
      elseif closing and i == closing then close = part
      elseif opening and i < opening then before[#before + 1] = part
      elseif closing and i > closing then after[#after + 1] = part
      else inner[#inner + 1] = part end
    end
    if vim.list_contains(rule.trailing or {}, kind) and inner[#inner] and inner[#inner].text == ',' then
      inner[#inner].ignorable = true
    end
    local nested = list(inner, open, close)
    if #before == 0 and #after == 0 then return stamp(nested, node) end
    before[#before + 1] = nested
    vim.list_extend(before, after)
    return stamp(list(before), node)
  end
  local children = {}
  for child in source.tree:root():iter_children() do
    local part = convert(child)
    if part then children[#children + 1] = part end
  end
  -- Keep a common virtual root; the reference returns top-level siblings,
  -- rather than collapsing the parser root on a one-statement file.
  local root = { children = children }
  if count > MAX_NODES then source.syntax = false; return nil end
  local serial = 0
  local function link(node, parent, depth)
    serial = serial + 1
    if checkpoint and serial % 256 == 0 then checkpoint() end
    node.id, node.parent, node.depth = serial, parent, depth
    node.descendants = 0
    for i, child in ipairs(node.children or {}) do
      child.next = node.children[i + 1]
      link(child, node, depth + 1)
      node.descendants = node.descendants + 1 + child.descendants
    end
  end
  if root then link(root, nil, 0) end
  source.syntax = root or false
  return root
end

local function content_ids(root, ids, checkpoint)
  if not root then return end
  ids.steps = (ids.steps or 0) + 1
  if checkpoint and ids.steps % 256 == 0 then checkpoint() end
  local parts = {}
  if root.children then
    parts = { 'list', root.open and root.open.text or '', root.close and root.close.text or '' }
    for _, child in ipairs(root.children) do
      content_ids(child, ids, checkpoint)
      if not child.ignorable then parts[#parts + 1] = child.content_id end
    end
  else
    local text = root.text
    if root.kind == 'comment' then text = text:gsub('\n[ \t]+', '\n') end
    parts = { root.kind == 'comment' and 'comment' or 'atom', text }
  end
  local key = vim.json.encode(parts)
  if not ids[key] then ids.count = ids.count + 1; ids[key] = ids.count end
  root.content_id = ids[key]
end

-- Persistent parent stacks preserve paired delimiter entry/exit. Separate
-- entries allow a node to retain its identity when wrapped at another depth.
local function push(stack, a, b, both)
  if not both and stack and not stack.both then
    return { prev = stack.prev, left = a and { node = a, prev = stack.left } or stack.left,
      right = b and { node = b, prev = stack.right } or stack.right }
  end
  return { prev = stack, both = both, left = a and { node = a }, right = b and { node = b } }
end
local function pop(a, b, stack)
  while stack do
    if stack.both then
      if a or b then break end
      a, b, stack = stack.left.node.next, stack.right.node.next, stack.prev
    elseif not a and stack.left then
      a = stack.left.node.next
      local left = stack.left.prev
      stack = (left or stack.right) and { prev = stack.prev, left = left, right = stack.right } or stack.prev
    elseif not b and stack.right then
      b = stack.right.node.next
      local right = stack.right.prev
      stack = (stack.left or right) and { prev = stack.prev, left = stack.left, right = right } or stack.prev
    else break end
  end
  return a, b, stack
end
local function stack_key(stack)
  if not stack then return '' end
  if stack.key then return stack.key end
  local parts = { stack_key(stack.prev), stack.both and 'B' or 'E' }
  for _, side in ipairs({ 'left', 'right' }) do
    parts[#parts + 1] = side
    local p = stack[side]
    while p do parts[#parts + 1] = p.node.id; p = p.prev end
  end
  stack.key = table.concat(parts, ':')
  return stack.key
end

local function characters(text, checkpoint)
  local result = {}
  for char in text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
    result[#result + 1] = char
    if checkpoint and #result % 512 == 0 then checkpoint() end
  end
  return result
end
local function similarity(a, b, checkpoint)
  a, b = characters(a, checkpoint), characters(b, checkpoint)
  local total = math.max(#a, #b, 1)
  -- Equal prefixes/suffixes cannot affect Levenshtein distance. Long prose
  -- with a small edit therefore compares just the edit, with no size cutoff.
  local first, last_a, last_b = 1, #a, #b
  while first <= last_a and first <= last_b and a[first] == b[first] do
    first = first + 1
    if checkpoint and first % 512 == 0 then checkpoint() end
  end
  while last_a >= first and last_b >= first and a[last_a] == b[last_b] do
    last_a, last_b = last_a - 1, last_b - 1
    if checkpoint and last_a % 512 == 0 then checkpoint() end
  end
  local len_a, len_b = last_a - first + 1, last_b - first + 1
  if len_a == 0 or len_b == 0 then return math.floor(100 * (1 - math.max(len_a, len_b) / total) + 0.5) end
  local row = {}
  for j = 0, len_b do
    row[j] = j
    if checkpoint and j % 512 == 0 then checkpoint() end
  end
  for i = 1, len_a do
    if checkpoint and i % 16 == 0 then checkpoint() end
    local previous = row[0]; row[0] = i
    for j = 1, len_b do
      if checkpoint and j % 512 == 0 then checkpoint() end
      local current = row[j]
      row[j] = math.min(row[j] + 1, row[j - 1] + 1, previous + (a[first + i - 1] == b[first + j - 1] and 0 or 1))
      previous = current
    end
  end
  return math.floor(100 * (1 - row[len_b] / total) + 0.5)
end

local function route(lhs, rhs, checkpoint)
  local heap, seen, buckets, serial, count, iterations = {}, {}, {}, 0, 0, 0
  local function less(a, b) return a.cost < b.cost or a.cost == b.cost and a.serial > b.serial end
  local function enqueue(value)
    heap[#heap + 1] = value
    local i = #heap
    while i > 1 do
      local parent = math.floor(i / 2)
      if not less(heap[i], heap[parent]) then break end
      heap[i], heap[parent], i = heap[parent], heap[i], parent
    end
  end
  local function dequeue()
    local first, tail = heap[1], table.remove(heap)
    if #heap > 0 then
      heap[1] = tail
      local i = 1
      while i * 2 <= #heap do
        local child = i * 2
        if heap[child + 1] and less(heap[child + 1], heap[child]) then child = child + 1 end
        if not less(heap[child], heap[i]) then break end
        heap[child], heap[i], i = heap[i], heap[child], child
      end
    end
    return first
  end
  local function step(from, a, b, stack, cost, action, pct)
    a, b, stack = pop(a, b, stack)
    local bucket_key = (a and a.id or ('p' .. (stack and stack.left and stack.left.node.id or 0)))
      .. '/' .. (b and b.id or ('p' .. (stack and stack.right and stack.right.node.id or 0)))
      .. '/' .. (stack and not stack.both and 'E' or 'B')
    local parent_key = stack_key(stack)
    local bucket = buckets[bucket_key]
    if not bucket then bucket = {}; buckets[bucket_key] = bucket end
    -- Like the reference, retain at most two delimiter stack variants per
    -- node pair. Exact stacks would grow exponentially with nesting depth.
    local variant
    for i, value in ipairs(bucket) do if value == parent_key then variant = i; break end end
    if not variant then
      if #bucket >= 2 then return end
      bucket[#bucket + 1] = parent_key; variant = #bucket
    end
    local key = bucket_key .. '/' .. variant
    cost = cost + (from and from.cost or 0)
    if seen[key] and seen[key] <= cost then return end
    if not seen[key] then count = count + 1 end
    seen[key] = cost; serial = serial + 1
    enqueue({ a = a, b = b, stack = stack, cost = cost, prev = from, action = action, pct = pct,
      serial = serial, key = key })
  end
  step(nil, lhs, rhs, nil, 0)
  while #heap > 0 do
    if count > MAX_GRAPH then return nil end
    if checkpoint and iterations % 256 == 0 then checkpoint() end
    iterations = iterations + 1
    local v = dequeue()
    if v.cost == seen[v.key] then
      local a, b, stack = v.a, v.b, v.stack
      if not a and not b and not stack then return v end
      if a and b then
        local depth = math.min(40, math.abs(a.depth - b.depth))
        if a.content_id == b.content_id then
          local punctuation = a.text == ',' or a.text == ';' or a.text == '.'
          step(v, a.next, b.next, stack, 1 + depth + (punctuation and 200 or 0), 'equal')
        end
        if a.children and b.children
          and (a.open and a.open.text or '') == (b.open and b.open.text or '')
          and (a.close and a.close.text or '') == (b.close and b.close.text or '') then
          step(v, a.children[1], b.children[1], push(stack, a, b, true), 10 + depth, 'delimiters')
        elseif not a.children and not b.children and a.kind == b.kind
          and (a.kind == 'string' or a.kind == 'comment' or a.kind == 'text') and a.text ~= b.text then
          local pct = similarity(a.text, b.text, checkpoint)
          step(v, a.next, b.next, stack, 600 - pct, 'replace', pct)
        end
      end
      if a then
        if a.children then step(v, a.children[1], b, push(stack, a, nil), 300, 'left')
        else step(v, a.next, b, stack, 300, 'left') end
      end
      if b then
        if b.children then step(v, a, b.children[1], push(stack, nil, b), 300, 'right')
        else step(v, a, b.next, stack, 300, 'right') end
      end
    end
  end
end

-- Only literal/comment replacements may match inside an atom. Identifiers
-- never acquire the character-level matching used by a textual word diff.
local function words(node, keep_numbers, checkpoint, limit)
  local result, offset, count = {}, node.first, 0
  for char in node.text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
    count = count + 1
    if checkpoint and count % 512 == 0 then checkpoint() end
    local kind = char:match('^%d$') and (keep_numbers and 'word' or 'number')
      or (char:match('^[%a_]$') or #char > 1 and vim.fn.charclass(char) == 2) and 'word' or 'other'
    local previous = result[#result]
    if kind ~= 'other' and previous and previous.kind == kind then
      previous.text, previous.last = previous.text .. char, offset + #char
    else result[#result + 1] = { text = char, first = offset, last = offset + #char, kind = kind } end
    offset = offset + #char
    if limit and #result > limit then return nil end
  end
  return result
end

-- Use the reference's Histogram selection, including repeated-token ties.
local linear_diff = require('git.features.syntax_linear_diff').diff

local function replaced(a, b, append, checkpoint)
  local left, right = words(a, false, checkpoint), words(b, false, checkpoint)
  local common, novel_count, unchanged_count = {}, 0, 0
  local changed = { old = {}, new = {} }
  linear_diff(left, right, function(part) return part.text end, function(side, part, opposite)
    if side == 'both' then
      common[#common + 1] = { part, opposite }
      if part.text ~= ' ' then unchanged_count = unchanged_count + 1 end
    else
      novel_count = novel_count + 1
      changed[side][#changed[side] + 1] = part
    end
  end, checkpoint)
  -- Reference has_common_words(): delimiters alone cannot justify accents,
  -- and an unrelated replacement with sparse shared words stays wholly muted.
  if unchanged_count <= 2 or unchanged_count * 2 < novel_count then
    append('old', a); append('new', b); return
  end
  for i, pair in ipairs(common) do
    if checkpoint and i % 256 == 0 then checkpoint() end
    append('old', pair[1]); append('new', pair[2])
  end
  for _, side in ipairs({ 'old', 'new' }) do
    for _, part in ipairs(changed[side]) do
      if a.kind == 'text' or not part.text:match('^%s+$') then append(side, part); append(side, part, true) end
    end
  end
end

-- The reference's line_parser: changed lines carry a muted base; a Histogram
-- word comparison supplies accents. Empty accents on a retained side never
-- mean that the whole line should be promoted to a strong background.
function M.text_compare(old_lines, new_lines)
  local result = { old = {}, new = {}, emphasis = { old = {}, new = {} } }
  local rows = { old = {}, new = {} }
  for _, side in ipairs({ 'old', 'new' }) do
    local lines = side == 'old' and old_lines or new_lines
    for row, line in ipairs(lines) do rows[side][row] = { text = line, row = row } end
  end
  local left, right = {}, {}
  local function flush()
    if #left == 0 and #right == 0 then return end
    local tokens, lengths, exceeded = { old = {}, new = {} }, { old = {}, new = {} }, {}
    for _, side in ipairs({ 'old', 'new' }) do
      local lines = side == 'old' and left or right
      for _, line in ipairs(lines) do
        lengths[side][line.row] = #line.text
        if #line.text > 0 then result[side][line.row] = { { 1, #line.text } } end
        if not exceeded[side] then
          local parts = words({ text = line.text .. '\n', first = 0 }, true, nil, 1000 - #tokens[side])
          if not parts then exceeded[side] = true
          else
            for _, part in ipairs(parts) do
              part.row = line.row
              tokens[side][#tokens[side] + 1] = part
            end
          end
        end
      end
    end
    local function accent(side, part)
      local finish = math.min(part.last, lengths[side][part.row])
      if finish > part.first then
        local spans = result.emphasis[side]
        spans[part.row] = spans[part.row] or {}
        spans[part.row][#spans[part.row] + 1] = { part.first + 1, finish }
      end
    end
    if exceeded.old or exceeded.new then
      for _, side in ipairs({ 'old', 'new' }) do
        for row, spans in pairs(lengths[side]) do
          if spans > 0 then result.emphasis[side][row] = { { 1, spans } } end
        end
      end
    else
      linear_diff(tokens.old, tokens.new, function(part) return part.text end, function(side, part)
        if side ~= 'both' then accent(side, part) end
      end)
    end
    left, right = {}, {}
  end
  linear_diff(rows.old, rows.new, function(line) return line.text end, function(side, line)
    if side == 'both' then flush()
    elseif side == 'old' then left[#left + 1] = line
    else right[#right + 1] = line end
  end)
  flush()
  return result
end

function M.text_fallback(old_lines, new_lines)
  local result = M.text_compare(old_lines, new_lines)
  -- Text NovelWord includes uncertain matching and word-limit fallback.
  -- Keep its ranges, without strong backgrounds or the whole-line base tint.
  result.old, result.new = result.emphasis.old, result.emphasis.new
  result.emphasis = { old = {}, new = {} }
  return result
end

-- Recovery results belong to the enclosing cached source pair. Temporary
-- fragment parses do not evict the full hunk or retain parser/tree objects.
function M.recover(old, new, old_lines, new_lines, lang, bufnr)
  local key = vim.mpack.encode({ old_lines, new_lines })
  local owner, opposite = old or new, new or old
  -- With neither parsed side (missing parser or both byte-limited), there is
  -- no live source pair for asynchronous structural recovery to subscribe to.
  if bufnr and not owner then return M.text_fallback(old_lines, new_lines), false end
  local recovery
  if owner then
    owner.recoveries = owner.recoveries or setmetatable({}, { __mode = 'k' })
    recovery = owner.recoveries[opposite]
    if not recovery then
      recovery = { results = {}, fragments = {} }
      owner.recoveries[opposite] = recovery
    end
    if recovery.results[key] then return recovery.results[key], false end
  end
  local fragments = recovery and recovery.fragments[key] or {}
  if recovery then recovery.fragments[key] = fragments end
  if fragments.parsing and fragments.parse_valid and not fragments.parse_valid() then fragments.parsing = nil end
  fragments.waiters = fragments.waiters or {}
  if bufnr then fragments.waiters[bufnr] = true end
  local function parse_pair(before, after, lhs, rhs, ready)
    if fragments[ready] or fragments.parsing then return end
    if bufnr and owner then
      local job = {}
      fragments.parsing = job
      local remaining = 2
      local function valid()
        local style = package.loaded['git.features.syntax_highlight']
        if fragments.parsing ~= job or recovery.fragments[key] ~= fragments then return false end
        for buffer in pairs(fragments.waiters) do
          if vim.api.nvim_buf_is_valid(buffer) and vim.api.nvim_buf_is_loaded(buffer)
            and (not style or style.config.word_diff_style == 'treesitter' and style.source_is_active(buffer, owner, opposite))
          then return true end
        end
        return false
      end
      fragments.parse_valid = valid
      local function parsed(field, source)
        if fragments.parsing ~= job then return end
        fragments[field] = source
        remaining = remaining - 1
        if remaining == 0 then
          fragments.parsing, fragments[ready] = false, true
          owner.versions = owner.versions or setmetatable({}, { __mode = 'k' })
          owner.versions[opposite] = (owner.versions[opposite] or 0) + 1
          for buffer in pairs(fragments.waiters) do
            if vim.api.nvim_buf_is_valid(buffer) and vim.api.nvim_buf_is_loaded(buffer) then refresh_when_ready(buffer) end
          end
        end
      end
      local function cancelled()
        if fragments.parsing == job then fragments.parsing = nil end
      end
      M.parse_async(before, lang, valid, function(source) parsed(lhs, source) end, cancelled)
      M.parse_async(after, lang, valid, function(source) parsed(rhs, source) end, cancelled)
    else
      fragments[lhs], fragments[rhs], fragments[ready] = M.parse(before, lang, false), M.parse(after, lang, false), true
    end
  end
  if structural_language(lang) then parse_pair(old_lines, new_lines, 'old', 'new', 'ready') end
  local function compare(a, b)
    if bufnr then return M.compare_async(a, b, bufnr, owner, opposite) end
    return M.compare(a, b), false
  end
  local result, pending
  if fragments.parsing then pending = true else result, pending = compare(fragments.old, fragments.new) end
  -- A declaration-only Git block has no body/end. Complete just this known
  -- Lua fragment shape so parameter changes retain structural correspondence.
  if not result and not pending and lang == 'lua' and #old_lines == 1 and #new_lines == 1 then
    local function declaration(line)
      return line:match('^%s*function%s+[%w_%.:]+%s*%b()%s*$')
        or line:match('^%s*local%s+function%s+[%w_]+%s*%b()%s*$')
    end
    if declaration(old_lines[1]) and declaration(new_lines[1]) then
      parse_pair({ old_lines[1], 'end' }, { new_lines[1], 'end' }, 'complete_old', 'complete_new', 'complete_ready')
      if fragments.parsing then pending = true else result, pending = compare(fragments.complete_old, fragments.complete_new) end
    end
  end
  if not result then
    fragments.fallback = fragments.fallback or M.text_fallback(old_lines, new_lines)
    result = fragments.fallback
  end
  if recovery and not pending then
    recovery.results[key] = result
    recovery.fragments[key] = nil
  end
  return result, pending
end

-- Compare the full parsed hunk. The view projects only its changed rows;
-- context anchors correspondence and one-sided changes receive token spans.
function M.compare(old, new, opts)
  if not old or not new then return nil end
  if not structural_language(old.lang) or not structural_language(new.lang) then return nil end
  if old.comparison and old.comparison.new == new then
    local cached = old.comparison.result
    if cached == false then return nil end
    return cached
  end
  local checkpoint = opts and opts.checkpoint
  local lhs, rhs = syntax_tree(old, checkpoint), syntax_tree(new, checkpoint)
  if not lhs or not rhs then return nil end
  local ids = { count = 0 }; content_ids(lhs, ids, checkpoint); content_ids(rhs, ids, checkpoint)
  local result = { old = {}, new = {}, emphasis = { old = {}, new = {} } }
  local function append(side, part, emphasis)
    if not part then return end
    local source = side == 'old' and old or new
    local first, last = part.first, part.last
    -- Seek the first affected source row instead of rescanning every earlier
    -- line for each token/word in a long hunk or multiline literal.
    local low, high = 1, #source.offsets
    while low <= high do
      local middle = math.floor((low + high) / 2)
      if source.offsets[middle] <= first then low = middle + 1 else high = middle - 1 end
    end
    local row = math.max(1, high)
    while source.offsets[row] and source.offsets[row] < last do
      local offset = source.offsets[row]
      local a, b = math.max(first, offset), math.min(last, offset + #source.lines[row])
      if b > a then
        local ranges = emphasis and result.emphasis[side] or result[side]
        ranges[row] = ranges[row] or {}
        ranges[row][#ranges[row] + 1] = { a - offset + 1, b - offset }
      end
      row = row + 1
    end
  end
  local function novel(side, node)
    if node.children then append(side, node.open); append(side, node.close)
    else append(side, node) end
  end
  local status = {}
  local walked = 0
  local function tick()
    walked = walked + 1
    if checkpoint and walked % 256 == 0 then checkpoint() end
  end
  local function deep_novel(node)
    tick()
    status[node] = false
    for _, child in ipairs(node.children or {}) do deep_novel(child) end
  end
  local function equal(a, b)
    tick()
    if old.lang == 'python' and a.statement_indent and b.statement_indent
      and a.statement_indent ~= b.statement_indent then
      deep_novel(a); deep_novel(b); return
    end
    status[a], status[b] = b, a
    for i, child in ipairs(a.children or {}) do equal(child, b.children[i]) end
  end
  local function shrink(left, right)
    local first, last_left, last_right, changed = 1, #left, #right, false
    while left[first] and right[first] and left[first].content_id == right[first].content_id do
      equal(left[first], right[first]); first, changed = first + 1, true
    end
    while last_left >= first and last_right >= first and left[last_left].content_id == right[last_right].content_id do
      equal(left[last_left], right[last_right]); last_left, last_right, changed = last_left - 1, last_right - 1, true
    end
    left, right = vim.list_slice(left, first, last_left), vim.list_slice(right, first, last_right)
    local a, b = left[1], right[1]
    if #left == 1 and #right == 1 and a.children and b.children
      and (a.open and a.open.text or '') == (b.open and b.open.text or '')
      and (a.close and a.close.text or '') == (b.close and b.close.text or '') then
      local nested, l, r = shrink(a.children, b.children)
      if nested then status[a], status[b] = b, a; return true, l, r end
    end
    return changed, left, right
  end
  -- Reference mark_unchanged preprocessing: trim matching ends, split off
  -- mostly unchanged top-level lists, and anchor equal subtrees with at least
  -- ten descendants. A large file then produces several small searches.
  local counts = { old = {}, new = {} }
  local function count_nodes(side, node)
    tick()
    local id = node.content_id
    counts[side][id] = (counts[side][id] or 0) + 1
    for _, child in ipairs(node.children or {}) do count_nodes(side, child) end
  end
  count_nodes('old', lhs); count_nodes('new', rhs)
  local function mostly(a, b)
    if not a.children or not b.children then return false end
    local opposite = {}
    local function collect(node)
      tick()
      if counts.new[node.content_id] == 1 then opposite[node.content_id] = true end
      for _, child in ipairs(node.children or {}) do collect(child) end
    end
    collect(b)
    local function common(node)
      tick()
      if counts.old[node.content_id] == 1 and opposite[node.content_id] then return 1 end
      local count = 0
      for _, child in ipairs(node.children or {}) do count = count + common(child) end
      return count
    end
    return common(a) >= 4
  end
  local split_nodes
  local function region(left, right)
    local a, b = left[1], right[1]
    if #left == 1 and #right == 1 and a.children and b.children
      and (a.open and a.open.text or '') == (b.open and b.open.text or '')
      and (a.close and a.close.text or '') == (b.close and b.close.text or '') then
      local nested = split_nodes(a.children, b.children)
      if #nested > 1 then
        table.insert(nested, 1, { kind = 'delimiters', a = a, b = b })
        return nested
      end
    end
    return { { kind = 'region', left = left, right = right } }
  end
  split_nodes = function(left, right)
    local plans, l, r = {}, {}, {}
    local function flush()
      if #l > 0 or #r > 0 then vim.list_extend(plans, region(l, r)); l, r = {}, {} end
    end
    linear_diff(left, right, function(node) return node.content_id end, function(side, node, opposite)
      if side == 'both' and node.children and node.descendants >= 10 then
        flush(); plans[#plans + 1] = { kind = 'equal', a = node, b = opposite }
      elseif side == 'both' then l[#l + 1], r[#r + 1] = node, opposite
      elseif side == 'old' then l[#l + 1] = node
      else r[#r + 1] = node end
    end, checkpoint)
    flush()
    return plans
  end
  local _, left, right = shrink(lhs.children, rhs.children)
  local groups, trailing = {}, {}
  while left[1] and right[1] and mostly(left[1], right[1]) do
    groups[#groups + 1] = { { table.remove(left, 1) }, { table.remove(right, 1) } }
  end
  while left[#left] and right[#right] and mostly(left[#left], right[#right]) do
    trailing[#trailing + 1] = { { table.remove(left) }, { table.remove(right) } }
  end
  if #left > 0 or #right > 0 then groups[#groups + 1] = { left, right } end
  for i = #trailing, 1, -1 do groups[#groups + 1] = trailing[i] end
  local plans = {}
  for _, group in ipairs(groups) do
    local _, l, r = shrink(group[1], group[2])
    vim.list_extend(plans, split_nodes(l, r))
  end
  for _, plan in ipairs(plans) do
    tick()
    if plan.kind == 'equal' then equal(plan.a, plan.b)
    elseif plan.kind == 'delimiters' then status[plan.a], status[plan.b] = plan.b, plan.a
    else
      local l, r = plan.left, plan.right
      local last_left, last_right = l[#l], r[#r]
      local next_left, next_right = last_left and last_left.next, last_right and last_right.next
      if last_left then last_left.next = nil end
      if last_right then last_right.next = nil end
      local end_vertex = route(l[1], r[1], checkpoint)
      if last_left then last_left.next = next_left end
      if last_right then last_right.next = next_right end
      if not end_vertex then old.comparison = { new = new, result = false }; return nil end
      local v = end_vertex
      while v.prev do
        tick()
        local a, b = v.prev.a, v.prev.b
        if v.action == 'equal' then equal(a, b)
        elseif v.action == 'delimiters' then status[a], status[b] = b, a
        elseif v.action == 'left' then status[a] = false
        elseif v.action == 'right' then status[b] = false
        elseif v.action == 'replace' then
          if v.pct > 20 then replaced(a, b, append, checkpoint) else append('old', a); append('new', b) end
        end
        v = v.prev
      end
    end
  end
  -- Correct the nested delimiter slider: foo(extra(bar())) should mark
  -- extra's parentheses rather than foo's. Data/Lisp lists prefer the outer.
  local function sliders(node)
    tick()
    if not node.children then return end
    if status[node] == false and old.lang ~= 'json' and old.lang ~= 'toml' then
      local found = {}
      local function unchanged(children)
        for _, child in ipairs(children) do
          tick()
          if status[child] then found[#found + 1] = child
          elseif child.children then unchanged(child.children) end
          if #found > 1 then return end
        end
      end
      unchanged(node.children)
      local child = found[1]
      if #found == 1 and child.children
        and (node.open and node.open.text or '') == (child.open and child.open.text or '')
        and (node.close and node.close.text or '') == (child.close and child.close.text or '') then
        local opposite = status[child]
        status[node], status[opposite], status[child] = opposite, node, false
      end
    end
    for _, child in ipairs(node.children) do sliders(child) end
  end
  sliders(lhs); sliders(rhs)
  local function paint(side, node)
    tick()
    if status[node] == false then novel(side, node) end
    for _, child in ipairs(node.children or {}) do paint(side, child) end
  end
  paint('old', lhs); paint('new', rhs)
  old.comparison = { new = new, result = result }
  return result
end

-- Private conversion graphs allow suspended comparisons to coexist without
-- mutating the cached hunk's sibling links/content IDs. Parsing remains shared.
function M.compare_async(old, new, bufnr, owner, opposite)
  if not old or not new then return nil, false end
  if not structural_language(old.lang) or not structural_language(new.lang) then return nil, false end
  if old.comparison and old.comparison.new == new then
    local result = old.comparison.result
    return result ~= false and result or nil, false
  end
  old.completed = old.completed or setmetatable({}, { __mode = 'k' })
  if old.completed[new] ~= nil then
    local result = old.completed[new]
    return result ~= false and result or nil, false
  end
  old.jobs = old.jobs or {}
  local job = old.jobs[new]
  local request = { source = owner or old, opposite = opposite or new }
  local function register(target)
    target.waiters[bufnr] = request
    target.owners[request.source] = target.owners[request.source] or {}
    target.owners[request.source][request.opposite] = true
  end
  if job then
    register(job)
    return nil, true
  end
  local function private(source)
    return { code = source.code, lines = source.lines, offsets = source.offsets, lang = source.lang, tree = source.tree }
  end
  job = { waiters = {}, owners = {} }
  register(job)
  old.jobs[new] = job
  local deadline
  job.thread = coroutine.create(function()
    return M.compare(private(old), private(new), { checkpoint = function()
      if vim.uv.hrtime() >= deadline then coroutine.yield() end
    end })
  end)
  local function resume(initial)
    if not initial then
      local style = package.loaded['git.features.syntax_highlight']
      for buf, request in pairs(job.waiters) do
        if not vim.api.nvim_buf_is_loaded(buf) or style and style.config.word_diff_style ~= 'treesitter' then
          job.waiters[buf] = nil
        elseif style and not style.source_is_active(buf, request.source, request.opposite) then
          job.waiters[buf] = nil
        end
      end
      if next(job.waiters) == nil then old.jobs[new] = nil; return end
    end
    deadline = vim.uv.hrtime() + 5e6
    local ok, result = coroutine.resume(job.thread)
    if not ok then
      old.jobs[new] = nil
      error(result)
    end
    if coroutine.status(job.thread) == 'dead' then
      old.jobs[new] = nil
      old.completed[new] = result or false
      old.comparison = { new = new, result = result or false }
      for source, opposites in pairs(job.owners) do
        source.versions = source.versions or setmetatable({}, { __mode = 'k' })
        for opposite in pairs(opposites) do source.versions[opposite] = (source.versions[opposite] or 0) + 1 end
      end
      if not initial then
        for buf in pairs(job.waiters) do refresh_when_ready(buf) end
      end
      return result, false
    end
    jobs.schedule(function() resume(false) end)
    return nil, true
  end
  jobs.schedule(function() resume(false) end)
  return nil, true
end

return M
