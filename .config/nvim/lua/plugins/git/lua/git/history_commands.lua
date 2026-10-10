local M = {}
local objects = require('git.objects')
local function commit_name(root, hash) return 'git-commit://' .. root .. '/0/' .. hash end

function M.open(o, location)
  local root, path, source = objects.context()
  local args = require('git.commands').argv(o.args)
  local file_history = o.range > 0 and o.line1 == 0
  local line_history = o.range > 0 and not file_history
  if file_history and o.line2 > 0 then _, path, source = objects.context(o.line2) end
  local query = { '-c', 'core.quotepath=false', 'log', '--no-color', '--no-ext-diff', '--format=%x1e%H%x09%s' }
  vim.list_extend(query, args)
  if line_history then
    assert(path, 'No current file')
    query[#query + 1] = '-L' .. o.line1 .. ',' .. o.line2 .. ':' .. path
    if source and source.revision and not vim.tbl_contains(args, source.revision) then query[#query + 1] = source.revision end
  elseif file_history then
    assert(path, 'No current file')
    vim.list_extend(query, { '--follow', '--name-status', '-z' })
    if source and source.revision then query[#query + 1] = source.revision end
    vim.list_extend(query, { '--', path })
  end
  local text = objects.run(root, query)
  local items, current_path = {}, path
  for record in text:gmatch('\30([^\30]+)') do
    local hash, subject, body = record:match('^(%x+)\t([^\n%z]*)[\n%z]*(.*)$')
    if hash then
      if line_history then
        local new_path = body:match('\n%+%+%+ b/([^\n]+)') or current_path
        local count = 0
        for row in body:gmatch('\n@@ [^\n]- %+(%d+)[^\n]-@@') do
          items[#items + 1] = { filename = objects.uri(root, hash .. ':' .. new_path), lnum = math.max(1, tonumber(row)),
            text = hash:sub(1, 8) .. ' ' .. subject }
          count = count + 1
        end
        if count == 0 then items[#items + 1] = { filename = objects.uri(root, hash .. ':' .. new_path), lnum = 1, text = subject } end
        current_path = body:match('\n%-%-%- a/([^\n]+)') or new_path
      elseif file_history then
        local fields = vim.split(body:gsub('^\n+', ''), '\0', { plain = true, trimempty = true })
        local old_path
        for i, field in ipairs(fields) do if field:match('^R%d+$') then old_path = fields[i + 1] end end
        items[#items + 1] = { filename = objects.uri(root, hash .. ':' .. current_path), lnum = 1, text = hash:sub(1, 8) .. ' ' .. subject }
        current_path = old_path or current_path
      else items[#items + 1] = { filename = commit_name(root, hash), lnum = 1, text = hash:sub(1, 8) .. ' ' .. subject } end
    end
  end
  local original = vim.api.nvim_get_current_win()
  if location then
    vim.fn.setloclist(0, {}, ' ', { title = 'Git history', items = items }); vim.cmd('lopen')
  else vim.fn.setqflist({}, ' ', { title = 'Git history', items = items }); vim.cmd('copen') end
  vim.api.nvim_set_current_win(original)
  if not o.bang and #items > 0 then vim.cmd(location and 'lfirst' or 'cfirst') end
end
return M
