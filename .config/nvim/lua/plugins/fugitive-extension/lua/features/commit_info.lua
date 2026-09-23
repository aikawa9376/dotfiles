-- Shared metadata for C floats and the pinned blame revision.
local M = {}
local function git(root, args)
  local cmd = { 'git', '--no-optional-locks', '-C', root }
  vim.list_extend(cmd, args)
  local result = vim.system(cmd, { text = true }):wait()
  if result.code ~= 0 then return nil, vim.trim(result.stderr or 'Git failed') end
  return vim.trim(result.stdout or '')
end
function M.lines(root, revision)
  local output, err = git(root, { 'show', '-s', '--date=format:%Y-%m-%d %H:%M',
    '--format=commit %H%ntree %T%nparent %P%nauthor %an <%ae> %ad (%ar)%ncommitter %cn <%ce> %cd (%cr)%nencoding %e%nrefs %D%n%n%B', revision })
  if not output then return nil, err end
  local lines = vim.split(output, '\n', { plain = true })
  local hash = lines[1]:match('^commit (%x+)')
  local head = git(root, { 'rev-parse', '--verify', 'HEAD' })
  local relation
  if head == hash then relation = 'HEAD'
  elseif head and hash then
    local counts = git(root, { 'rev-list', '--left-right', '--count', head .. '...' .. hash })
    local head_only, commit_only = (counts or ''):match('^(%d+)%s+(%d+)$')
    head_only, commit_only = tonumber(head_only), tonumber(commit_only)
    if commit_only == 0 then
      local count = git(root, { 'rev-list', '--first-parent', '--count', hash .. '..' .. head })
      local ancestor = count and git(root, { 'rev-parse', '--verify', head .. '~' .. count })
      relation = ancestor == hash and ('HEAD~' .. count) or (head_only .. ' commits behind HEAD; merged history')
    elseif head_only == 0 then relation = commit_only .. ' commits ahead of HEAD'
    elseif head_only then relation = ('diverged from HEAD: HEAD +%d / commit +%d'):format(head_only, commit_only) end
  end
  if relation then lines[1] = lines[1] .. ' (' .. relation .. ')' end
  local result, in_header = {}, true
  for _, line in ipairs(lines) do
    if line == '' then in_header = false end
    if in_header and line:match('^parent ') then
      for parent in line:sub(8):gmatch('%x+') do result[#result + 1] = 'parent ' .. parent end
    elseif not (in_header and (line == 'refs ' or line == 'refs' or line == 'encoding '
      or line == 'encoding <unknown>' or line == 'parent ')) then
      result[#result + 1] = line
    end
  end
  return result
end
function M.header(root, revision)
  local lines, err = M.lines(root, revision)
  if not lines then return nil, err end
  local header = {}
  for _, line in ipairs(lines) do
    header[#header + 1] = line
    if line == '' then break end
  end
  return header
end
return M
