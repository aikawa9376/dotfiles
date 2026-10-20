local M = {}

-- Byte offsets are one-based and inclusive. Keep them intact through masking so
-- searches, completion edits and refactoring all use the same source ranges.
function M.mask_comments(text)
  local function blank(s) return (s:gsub("[^\n]", " ")) end
  text = text:gsub("{{--.-%-%-}}", blank):gsub("<!%-%-.-%-%->", blank)
  text = text:gsub("@verbatim.-@endverbatim", blank)
  return text
end

function M.tokens(text)
  text = M.mask_comments(text)
  local tokens, i = {}, 1
  while i <= #text do
    local ch, pair = text:sub(i, i), text:sub(i, i + 1)
    if ch:match("%s") then
      i = i + 1
    elseif pair == "//" or (ch == "#" and text:sub(i + 1, i + 1) ~= "[") then
      i = text:find("\n", i, true) or (#text + 1)
    elseif pair == "/*" then
      i = (text:find("*/", i + 2, true) or (#text - 1)) + 2
    elseif text:sub(i, i + 2) == "<<<" then
      local label = text:sub(i):match("^<<<['\"]?([%w_]+)['\"]?%s*\r?\n")
      if label then
        local _, ending = text:find("\n[ \t]*" .. label .. "%f[^%w_]", i + 3)
        i = ending and ending + 1 or #text + 1
      else i = i + 3 end
    elseif ch == "'" or ch == '"' then
      local start, value, dynamic = i, {}, false
      i = i + 1
      while i <= #text and text:sub(i, i) ~= ch do
        local c = text:sub(i, i)
        if c == "\\" then
          local following = text:sub(i + 1, i + 1)
          value[#value + 1] = (following == "\\" or following == ch) and following or (c .. following)
          i = i + 2
        else
          if ch == '"' and c == "$" then dynamic = true end
          value[#value + 1], i = c, i + 1
        end
      end
      tokens[#tokens + 1] = { kind = "string", value = table.concat(value), start = start,
        finish = i, dynamic = dynamic, closed = i <= #text }
      i = i + 1
    else
      local word
      if ch:match("[%a_$\\]") then
        local last = i + 1
        while text:sub(last, last):match("[%w_$\\]") do last = last + 1 end
        word = text:sub(i, last - 1)
      end
      local value = word or ((pair == "::" or pair == "->" or pair == "=>") and pair) or ch
      tokens[#tokens + 1] = { kind = word and "word" or "symbol", value = value,
        start = i, finish = i + #value - 1 }
      i = i + #value
    end
  end
  local stack, close = {}, { [")"] = "(", ["]"] = "[", ["}"] = "{" }
  for n, t in ipairs(tokens) do
    if t.value == "(" or t.value == "[" or t.value == "{" then
      stack[#stack + 1] = n
    elseif close[t.value] and #stack > 0 and tokens[stack[#stack]].value == close[t.value] then
      local opening = table.remove(stack)
      tokens[opening].pair, t.pair = n, opening
    end
  end
  return tokens
end

function M.args(tokens, opening)
  local last = tokens[opening] and tokens[opening].pair
  if not last then return {} end
  local args, first, i = {}, opening + 1, opening + 1
  while i < last do
    if tokens[i].value == "," then
      args[#args + 1], first = { first, i - 1 }, i + 1
    elseif tokens[i].pair and tokens[i].pair > i then
      i = tokens[i].pair
    end
    i = i + 1
  end
  if first < last then args[#args + 1] = { first, last - 1 } end
  return args
end

function M.literal(tokens, arg)
  if not arg then return end
  local first = arg[1]
  if tokens[first + 1] and tokens[first + 1].value == ":" then first = first + 2 end
  local t = tokens[first]
  if first == arg[2] and t and t.kind == "string" and t.closed and not t.dynamic then return t end
end

function M.position(text, offset)
  local before = text:sub(1, offset - 1)
  local _, row = before:gsub("\n", "")
  local start = before:match(".*\n()") or 1
  return row + 1, offset - start + 1
end

function M.offset(text, row, col)
  local pos = 1
  for _ = 2, row do pos = (text:find("\n", pos, true) or #text) + 1 end
  return pos + col
end

-- A quote-aware tag scanner: > inside :prop="a > b" must not end the tag.
function M.html_tags(text)
  local clean, tags, from = M.mask_comments(text), {}, 1
  while true do
    local first, last, closing, full = clean:find("<%s*(/?)%s*([%w_.:%-]+)", from)
    if not first then break end
    local prefix, name
    if full:sub(1, 2) == "x-" then prefix, name = "x", full:sub(3)
    elseif full:sub(1, 9) == "livewire:" then prefix, name = "livewire", full:sub(10)
    else prefix, name = "html", full end
    local i, quote = last + 1, nil
    while i <= #clean do
      local c = clean:sub(i, i)
      if quote then
        if c == quote then quote = nil end
      elseif c == '"' or c == "'" then quote = c
      elseif c == ">" then break end
      i = i + 1
    end
    if prefix ~= "" then
      tags[#tags + 1] = { kind = prefix == "x" and "component" or prefix, name = name,
        start = last - #name + 1, finish = last, tag_start = first, tag_end = i,
        attrs_start = last + 1, closing = closing == "/" }
    end
    from = math.max(i + 1, last + 1)
  end
  return tags
end

function M.tags(text)
  return vim.tbl_filter(function(t) return t.kind ~= "html" end, M.html_tags(text))
end

function M.attributes(text, tag)
  local attrs, i = {}, tag.attrs_start
  while i < tag.tag_end do
    local first, last, name = text:find("([:@%w_.%-]+)", i)
    if not first or first >= tag.tag_end then break end
    local attr = { name = name, start = first, finish = last }
    i = last + 1
    local equal = text:sub(i):match("^%s*=%s*()")
    if equal then
      i = i + equal - 1
      local quote = text:sub(i, i)
      if quote == '"' or quote == "'" then
        attr.value_start = i + 1
        local ending = text:find(quote, i + 1, true)
        attr.value_end = ending and ending - 1 or tag.tag_end - 1
        attr.value = text:sub(attr.value_start, attr.value_end)
        i = ending and ending + 1 or tag.tag_end
      else
        local value = text:sub(i):match("^[^%s>]+") or ""
        attr.value_start, attr.value_end, attr.value = i, i + #value - 1, value
        i = i + math.max(1, #value)
      end
    end
    attrs[#attrs + 1] = attr
  end
  return attrs
end

local directives = { extends = 1, include = 1, includeIf = 1, includeIsolated = 1,
  includeWhen = 2, includeUnless = 2, includeFirst = 1, each = 1,
  component = 1, componentFirst = 1, livewire = 1 }

function M.references(text, opts)
  opts = opts or {}
  local refs, tokens = {}, M.tokens(text)
  local aliases = {}
  for i, t in ipairs(tokens) do
    if t.value == "use" and tokens[i + 1] then
      local class = tokens[i + 1].value:match("([^\\]+)$")
      if class == "View" or class == "Route" then
        local alias = tokens[i + 2] and tokens[i + 2].value == "as" and tokens[i + 3]
        aliases[alias and alias.value or class] = class
      end
    end
  end
  local function add(t, kind)
    if not t then return end
    refs[#refs + 1] = { kind = kind, name = t.value, start = t.start + 1, finish = t.finish - 1 }
  end
  for i, t in ipairs(tokens) do
    if tokens[i + 1] and tokens[i + 1].value == "(" then
      local prev, owner = tokens[i - 1], tokens[i - 2]
      local directive = prev and prev.value == "@" and not (owner and owner.value == "@")
      local kind, arg
      if directive and directives[t.value] then
        kind, arg = t.value == "livewire" and "livewire" or "view", directives[t.value]
      elseif not opts.blade and t.value == "view" and (not prev or (prev.value ~= "->" and prev.value ~= "::")) then
        kind, arg = "view", 1
      elseif not opts.blade and prev and prev.value == "::" and owner then
        local class = aliases[owner.value] or owner.value:match("([^\\]+)$")
        if class == "View" and (t.value == "make" or t.value == "first") then kind, arg = "view", 1
        elseif class == "Route" and t.value == "view" then kind, arg = "view", 2 end
      elseif not opts.blade and prev and prev.value == "->" and t.value == "view" then
        local open = owner and owner.value == ")" and owner.pair
        if open and tokens[open - 1] and tokens[open - 1].value == "response" then kind, arg = "view", 1 end
      end
      if kind then
        local args = M.args(tokens, i + 1)
        local target = args[arg]
        local literal = M.literal(tokens, target)
        if literal then add(literal, kind)
        elseif target and tokens[target[1]].value == "[" then
          for _, element in ipairs(M.args(tokens, target[1])) do add(M.literal(tokens, element), kind) end
        end
      end
    end
  end
  if opts.blade then
    local clean = M.mask_comments(text)
    local function expression(first, last)
      for _, ref in ipairs(M.references(clean:sub(first, last), { no_tags = true })) do
        ref.start, ref.finish = ref.start + first - 1, ref.finish + first - 1
        refs[#refs + 1] = ref
      end
    end
    for _, delimiters in ipairs({ {"{{", "}}"}, {"{!!", "!!}"}, {"<?php", "?>"}, {"@php", "@endphp"} }) do
      local from = 1
      while true do
        local first, last = clean:find(delimiters[1], from, true)
        if not first then break end
        local ending, after = clean:find(delimiters[2], last + 1, true)
        local inline_php = delimiters[1] == "@php" and clean:sub(last + 1):match("^%s*%(")
        if not inline_php and clean:sub(first - 1, first - 1) ~= "@"
            and (ending or delimiters[1] == "<?php") then expression(last + 1, ending and ending - 1 or #clean) end
        from = after and after + 1 or #clean + 1
      end
    end
    for i, t in ipairs(tokens) do
      if t.value == "@" and (not tokens[i - 1] or tokens[i - 1].value ~= "@")
          and tokens[i + 2] and tokens[i + 2].value == "(" and tokens[i + 2].pair then
        expression(tokens[i + 2].finish + 1, tokens[tokens[i + 2].pair].start - 1)
      end
    end
  end
  if not opts.no_tags then for _, tag in ipairs(M.tags(text)) do refs[#refs + 1] = tag end end
  local seen = {}
  refs = vim.tbl_filter(function(ref)
    local key = ref.start .. ":" .. ref.finish .. ":" .. ref.kind
    if seen[key] then return false end
    seen[key] = true
    return true
  end, refs)
  table.sort(refs, function(a, b) return a.start < b.start end)
  return refs
end

return M
