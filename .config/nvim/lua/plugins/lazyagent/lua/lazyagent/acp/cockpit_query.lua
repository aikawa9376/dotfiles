local M = {}
local fields = {
  status = true, provider = true, model = true, workspace = true, team = true,
  review = true, test = true, activity = true, unread = true, pinned = true,
  attention = true, updates = true, live = true, tracked = true,
}
local boolean = { unread = true, pinned = true, attention = true, updates = true, live = true, tracked = true }
local exact = { status = true, review = true, test = true }

local function lex(query)
  local tokens, chars, quote, literal, quoted_start = {}, {}, nil, false, false
  local function finish()
    if #chars > 0 then tokens[#tokens + 1] = { text = table.concat(chars), literal = literal,
      negate = not quoted_start and chars[1] == "-" and #chars > 1 } end
    chars, literal, quoted_start = {}, false, false
  end
  local i = 1
  while i <= #query do
    local char = query:sub(i, i)
    if quote then
      if char == quote then quote = nil
      elseif char == "\\" and (query:sub(i + 1, i + 1) == quote or query:sub(i + 1, i + 1) == "\\") then
        i = i + 1; chars[#chars + 1] = query:sub(i, i)
      else chars[#chars + 1] = char end
    elseif (char == '"' or char == "'") and (#chars == 0 or chars[#chars] == ":" or (#chars == 1 and chars[1] == "-")) then
      quote = char
      if #chars == 0 then quoted_start = true end
      if #chars == 0 or (#chars == 1 and chars[1] == "-") then literal = true end
    elseif char:match("%s") then finish()
    else chars[#chars + 1] = char end
    i = i + 1
  end
  if quote then return nil, "Unclosed quote in filter" end
  finish()
  return tokens
end

function M.compile(query)
  query = vim.trim(tostring(query or ""))
  local tokens, err = lex(query)
  if not tokens then return nil, err end
  local terms, structured = {}, false
  for _, token in ipairs(tokens) do
    local value = token.text
    local negate = token.negate
    if negate then value = value:sub(2) end
    local key, body = value:match("^([%a_]+):(.*)$")
    key = key and key:lower() or nil
    if token.literal or not fields[key] then key, body = nil, value end
    if key then
      if body == "" then return nil, "Missing value for " .. key end
      body = body:lower()
      if boolean[key] and body ~= "true" and body ~= "false" then return nil, key .. " expects true or false" end
      structured = true
    else body = value:lower() end
    structured = structured or negate or token.literal
    terms[#terms + 1] = { field = key or "text", value = body, negate = negate }
  end
  -- Keep existing plain multiword searches as one literal substring.
  if not structured and query ~= "" then terms = { { field = "text", value = query:lower() } } end
  return { terms = terms }
end

function M.matches(compiled, attributes)
  for _, term in ipairs(compiled.terms) do
    local actual = attributes[term.field]
    local matched
    if term.field == "workspace" and term.value == "current" then matched = attributes.current_workspace == true
    elseif boolean[term.field] then matched = (actual == true) == (term.value == "true")
    elseif exact[term.field] then
      matched = false
      for value in term.value:gmatch("[^,]+") do
        if tostring(actual or ""):lower() == value then matched = true; break end
      end
    else matched = tostring(actual or ""):lower():find(term.value, 1, true) ~= nil end
    if term.negate then matched = not matched end
    if not matched then return false end
  end
  return true
end

return M
