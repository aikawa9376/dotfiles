-- Completion domains follow the argument being entered, never one shared list.
local M = {}
local objects = require('git.objects')
local subcommands = { 'add', 'bisect', 'blame', 'branch', 'checkout', 'cherry-pick', 'clean', 'commit', 'diff', 'fetch', 'grep', 'log', 'merge', 'mv', 'pull', 'push', 'rebase', 'reflog', 'remote', 'reset', 'restore', 'revert', 'rm', 'show', 'stash', 'status', 'switch', 'tag', 'worktree' }
local flags = {
  log = { '--all', '--oneline', '--graph', '--follow', '--first-parent', '--author=', '--since=', '--until=', '--max-count=' },
  diff = { '--cached', '--staged', '--stat', '--name-only', '--name-status', '--word-diff', '--check' },
  show = { '--stat', '--name-only', '--format=', '--no-patch' },
  add = { '--all', '--patch', '--update', '--intent-to-add' },
  commit = { '--amend', '--no-edit', '--message=', '--fixup=', '--squash=', '--all' },
  rebase = { '--interactive', '--continue', '--abort', '--skip', '--autosquash', '--onto' },
  merge = { '--abort', '--continue', '--no-ff', '--ff-only', '--squash' },
  reset = { '--soft', '--mixed', '--hard' }, restore = { '--staged', '--worktree', '--source=' },
  checkout = { '--detach', '--ours', '--theirs', '--track' }, switch = { '--create', '--detach', '--track' },
  status = { '--short', '--branch', '--porcelain' },
  push = { '--force-with-lease', '--set-upstream', '--tags', '--delete', '--dry-run' },
  fetch = { '--all', '--prune', '--tags' }, pull = { '--rebase', '--ff-only' },
  blame = { '--reverse', '--porcelain', '--line-porcelain', '--show-email' },
}
local function root()
  local ok, value = pcall(objects.context)
  return ok and value or nil
end
local function read(repo, args, separator)
  if not repo then return {} end
  local ok, text = pcall(objects.run, repo, args)
  return ok and vim.split(text, separator or '\n', { plain = true, trimempty = true }) or {}
end
local function unescape(s) return (s:gsub('\\(.)', '%1')) end
local function finish(items, lead)
  lead = unescape(lead or '')
  local result, seen = {}, {}
  for _, item in ipairs(items) do
    if item:sub(1, #lead) == lead and not seen[item] then
      seen[item] = true
      result[#result + 1] = item:gsub('([\\%s"\'])', '\\%1')
    end
  end
  table.sort(result); return result
end
function M.refs(lead)
  local items = { 'HEAD', 'HEAD~', 'HEAD^', 'ORIG_HEAD', 'FETCH_HEAD' }
  vim.list_extend(items, read(root(), { 'for-each-ref', '--format=%(refname:short)' }))
  vim.list_extend(items, read(root(), { 'stash', 'list', '--format=%gd' }))
  return finish(items, lead)
end
function M.objects(lead)
  local raw, repo = unescape(lead), root()
  local prefix, path = raw:match('^(:[0-3]:)(.*)$')
  local paths
  if prefix then paths = read(repo, { 'ls-files', '-z' }, '\0')
  else
    prefix, path = raw:match('^(.-:)(.*)$')
    if prefix then
      if prefix == ':' then paths = read(repo, { 'ls-files', '-z' }, '\0')
      else
        local revision = prefix:sub(1, -2)
        if revision:match('^>?[~^]%d*$') then
          local ok, _, resolved = pcall(objects.resolve, revision .. ':%')
          if ok then revision = resolved:match('^(.-):') or revision end
        end
        paths = read(repo, { 'ls-tree', '-rz', '--name-only', revision }, '\0')
      end
    end
  end
  if not prefix then
    local refs = M.refs(lead)
    vim.list_extend(refs, finish({ '%', ':', ':0:%', ':1:%', ':2:%', ':3:%', '~1', '~2', '^', '^2', '>~1' }, lead))
    return refs
  end
  local items = { prefix .. '%' }
  local directory = path:match('^(.*)/')
  local length = directory and #directory + 2 or 1
  for _, p in ipairs(paths or {}) do
    local slash = p:find('/', length, true)
    items[#items + 1] = prefix .. (slash and p:sub(1, slash) or p)
  end
  return finish(items, lead)
end
function M.files(lead, _, _, directories)
  if lead:sub(1, 1) == ':' then return M.objects(lead) end
  local repo = root(); if not repo then return {} end
  local raw = unescape(lead)
  local parent = raw:match('^(.*)/') or ''
  local absolute = parent:sub(1, 1) == '/' and parent or repo .. '/' .. parent
  local items = {}
  local ok, iterator = pcall(vim.fs.dir, absolute)
  if not ok then return {} end
  for name, kind in iterator do
    if name ~= '.git' and (not directories or kind == 'directory') then
      items[#items + 1] = (parent ~= '' and parent .. '/' or '') .. name .. (kind == 'directory' and '/' or '')
    end
  end
  return finish(items, lead)
end
function M.dirs(lead) return M.files(lead, nil, nil, true) end
local function before(lead, line, pos)
  local text = line:sub(1, pos or #line)
  text = text:sub(1, #text - #lead)
  local ok, args = pcall(require('git.commands').argv, text)
  return ok and args or {}
end
function M.git(lead, line, pos)
  local args = before(lead, line, pos)
  local index = 2
  local takes_value = { ['-C'] = true, ['-c'] = true, ['--git-dir'] = true, ['--work-tree'] = true }
  while args[index] and args[index]:sub(1, 1) == '-' do
    local option = args[index]
    if takes_value[option] and not args[index + 1] then
      return option == '-c' and {} or M.dirs(lead)
    end
    index = index + (takes_value[option] and 2 or 1)
  end
  local normalized = { args[1] }
  vim.list_extend(normalized, vim.list_slice(args, index))
  args = normalized
  local sub = args[2]
  if not sub then
    if lead:sub(1, 1) == '-' then return finish({ '--no-pager', '--paginate', '--git-dir=', '--work-tree=', '-C', '-c' }, lead) end
    return finish(subcommands, lead)
  end
  local previous = args[#args]
  if previous == '-m' or previous == '--message' or previous == '--author' or previous == '--since' or previous == '--until' then return {} end
  if previous == '-F' or previous == '--file' then return M.files(lead) end
  if previous == '--source' or previous == '--onto' then return M.refs(lead) end
  for _, token in ipairs(args) do if token == '--' then return M.files(lead) end end
  local revision_flag = lead:match('^(%-%-[%w-]+=)')
  if revision_flag and vim.tbl_contains({ '--source=', '--fixup=', '--squash=' }, revision_flag) then
    local items = M.refs(lead:sub(#revision_flag + 1))
    return vim.tbl_map(function(item) return revision_flag .. item end, items)
  end
  if lead:sub(1, 1) == '-' then return finish(flags[sub] or {}, lead) end
  if sub == 'add' or sub == 'rm' or sub == 'mv' or sub == 'restore' or sub == 'clean' or sub == 'blame' or sub == 'commit' or sub == 'status' then return M.files(lead) end
  if (sub == 'push' or sub == 'pull' or sub == 'fetch') and #args == 2 then return finish(read(root(), { 'remote' }), lead) end
  if sub == 'stash' then
    if #args == 2 then return finish({ 'push', 'pop', 'apply', 'list', 'show', 'drop', 'clear', 'branch' }, lead) end
    if args[3] == 'push' then return M.files(lead) end
    return finish(read(root(), { 'stash', 'list', '--format=%gd' }), lead)
  end
  if sub == 'worktree' and #args == 2 then return finish({ 'add', 'list', 'lock', 'move', 'prune', 'remove', 'repair', 'unlock' }, lead) end
  if sub == 'remote' then
    if #args == 2 then return finish({ 'add', 'remove', 'rename', 'set-url', 'get-url', 'prune', 'show', 'update' }, lead) end
    return finish(read(root(), { 'remote' }), lead)
  end
  return M.objects(lead)
end
function M.log(lead, line, pos)
  local text = line:sub(1, pos or #line)
  local tail = text:match('^%S+%s(.*)$') or ''
  local command = 'Git log ' .. tail
  return M.git(lead, command, #command)
end
return M
