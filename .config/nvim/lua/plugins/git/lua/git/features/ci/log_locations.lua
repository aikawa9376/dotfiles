-- Explicit source locations and structurally bounded diagnostic blocks.
local M = {}
local function content(line)
  return (line:gsub('^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d[%d%.]*Z%s?', ''))
end
local function location(value)
  value = vim.trim(value):gsub('^["\']', ''):gsub('["\',;%)%]]+$', '')
  local path, row, col = value:match('^(.-):(%d+):(%d+):?$')
  if not path then path, row = value:match('^(.-):(%d+):?$') end
  if not path or path == '' or path:find('://', 1, true) or path:find('%c') or tonumber(row) < 1
    or (col and tonumber(col) < 1) then return end
  return { path = path, row = tonumber(row), col = tonumber(col) or 1 }
end
local function excerpt(line)
  return line:match('^%s*%d+%s*|') or line:match('^%s*[|%^~]') or line:match('^%s*=%s')
end
local function parse(line)
  if excerpt(line) then return {} end
  local arrow = line:match('^%s*%-%->%s*(.+)$')
  if arrow then return { location(arrow) } end
  local found = {}
  -- Quoted filenames may contain spaces. Mask them before scanning tokens.
  line = line:gsub('(["\'])(.-)%1', function(quote, value)
    local loc = location(value)
    if loc then found[#found + 1] = loc end
    return string.rep(' ', #value + 2)
  end)
  for token in line:gmatch('%S+') do
    local loc = location(token:gsub('^[%(%[]', ''))
    if loc then found[#found + 1] = loc end
  end
  return found
end
local function single(list)
  local result
  for _, loc in ipairs(list) do
    if result and not vim.deep_equal(result, loc) then return end
    result = loc
  end
  return result
end
local function diagnostic(line)
  return line:match('^%s*warning[:%[]') or line:match('^%s*error[:%[]')
    or line:match('^%s*hint[:%[]') or line:match('^%s*info[:%[]')
end
local function boundary(line)
  return vim.trim(line) == '' or line:match('^%s*%-%-%-') or line:match('^%s*##%[')
end
function M.index(lines)
  local text, anchors, rows = {}, {}, {}
  for row, line in ipairs(lines) do
    text[row] = content(line)
    anchors[row] = parse(text[row])
    rows[row] = single(anchors[row])
  end
  -- A paragraph with one unambiguous location can be opened from any row.
  local first = 1
  while first <= #lines do
    if boundary(text[first]) then first = first + 1
    else
      local last, candidates = first, {}
      while last <= #lines and not boundary(text[last]) do
        vim.list_extend(candidates, anchors[last]); last = last + 1
      end
      local loc = single(candidates)
      if loc then for row = first, last - 1 do rows[row] = rows[row] or loc end end
      first = last
    end
  end
  -- Compiler/LuaLS diagnostic: severity message, --> location, blank lines,
  -- numbered source excerpt and caret/notes. Never extend to ordinary output.
  for first, line in ipairs(text) do
    if diagnostic(line) then
      local at = first + 1
      while at <= math.min(first + 5, #lines) and not diagnostic(text[at])
        and (vim.trim(text[at]) == '' or text[at]:match('^%s+'))
        and not text[at]:match('^%s*%-%->') do at = at + 1 end
      if text[at] and text[at]:match('^%s*%-%->') then
        local last, candidates = at, {}
        vim.list_extend(candidates, anchors[at])
        while text[last + 1] and (vim.trim(text[last + 1]) == '' or excerpt(text[last + 1])) do last = last + 1 end
        local loc = single(candidates)
        if loc then for row = first, last do rows[row] = loc end end
      end
    end
  end
  return rows
end
function M.relative(root, path)
  local abs
  if path:sub(1, 1) == '/' then abs = vim.fs.normalize(path)
  else abs = vim.fs.normalize(root .. '/' .. path) end
  root = vim.fs.normalize(root):gsub('/+$', '')
  if abs:sub(1, #root + 1) ~= root .. '/' then return end
  return abs, abs:sub(#root + 2)
end
return M
