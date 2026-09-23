-- Git-only blame data. No Fugitive buffer names or commands are required.
local M = {}
function M.git(root, args)
  local argv = { 'git', '--no-optional-locks', '-C', root }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait()
  if result.code ~= 0 then return nil, vim.trim(result.stderr or 'Git failed') end
  return result.stdout or ''
end
local function unquote(path)
  if path:sub(1, 1) ~= '"' then return path end
  return path:sub(2, -2):gsub('\\(%d%d%d)', function(n) return string.char(tonumber(n, 8)) end)
    :gsub('\\(.)', function(c) return ({ n = '\n', t = '\t', r = '\r', b = '\b', ['\\'] = '\\', ['"'] = '"' })[c] or c end)
end
function M.parse(output)
  local rows, lines, current = {}, {}, nil
  for line in output:gmatch('[^\n]+') do
    local hash, original, final = line:match('^(%x+) (%d+) (%d+)')
    if hash then
      current = { commit = hash, original = tonumber(original), line = tonumber(final), uncommitted = hash:match('^0+$') ~= nil }
    elseif current then
      local key, value = line:match('^(%S+) (.*)$')
      if line:sub(1, 1) == '\t' then
        rows[current.line], lines[current.line] = current, line:sub(2)
        current = nil
      elseif key == 'author' then current.author = value
      elseif key == 'author-time' then current.timestamp = tonumber(value)
      elseif key == 'summary' then current.summary = value
      elseif key == 'filename' then current.path = unquote(value)
      elseif key == 'previous' then
        current.previous, current.previous_path = value:match('^(%x+) (.*)$')
        current.previous_path = unquote(current.previous_path or '')
      end
    end
  end
  return rows, lines
end
function M.load(root, path, revision, contents, callback)
  local args = { 'git', '--no-optional-locks', '-C', root, 'blame', '-w', '--line-porcelain' }
  if revision then args[#args + 1] = revision else vim.list_extend(args, { '--contents', '-' }) end
  vim.list_extend(args, { '--', path })
  return vim.system(args, { text = true, stdin = not revision and contents or nil }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then callback(nil, vim.trim(result.stderr or 'Git blame failed')); return end
      local rows, lines = M.parse(result.stdout or '')
      callback({ path = path, revision = revision, rows = rows, lines = lines })
    end)
  end)
end
-- Map a line in the new file to its old location, anchoring inserted lines at
-- the adjacent old line rather than searching by possibly duplicated text.
function M.old_line(old, new, line)
  local offset = 0
  for _, h in ipairs(vim.diff(old, new, { result_type = 'indices', ctxlen = 0 })) do
    local a, ac, b, bc = unpack(h)
    if bc > 0 and line >= b and line < b + bc then
      return math.max(1, a + math.min(line - b, math.max(ac - 1, 0)))
    end
    if (bc == 0 and line > b) or (bc > 0 and line >= b + bc) then offset = offset + ac - bc else break end
  end
  return math.max(1, line + offset)
end
return M
