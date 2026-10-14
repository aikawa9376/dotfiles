-- Git object buffers are owned here; no Vimscript autoload functions are used.
local M = {}
local utils = require('git.utils')
local function empty_tree(root)
  return vim.trim(M.run(root, { 'hash-object', '-t', 'tree', '--stdin' }, ''))
end
function M.attach_gitsigns(buf, root, path, base, base_path)
  if not path or not base then return end
  local ok, gitsigns = pcall(require, 'gitsigns')
  if ok then
    gitsigns.attach({ bufnr = buf, force = true, ctx = {
      file = base_path or path, toplevel = root, gitdir = utils.get_git_dir(root), base = base,
    } })
  end
end
local function comparison_base(root, revision, stage)
  if stage then return stage == '0' and 'HEAD' or ':1' end
  if not revision then return nil end
  local ok, commit = pcall(M.run, root, { 'rev-parse', '--verify', '--end-of-options', revision .. '^{commit}' })
  if not ok then return nil end
  commit = vim.trim(commit)
  local head_ok, head = pcall(M.run, root, { 'rev-parse', '--verify', 'HEAD' })
  if head_ok and vim.trim(head) ~= commit then return 'HEAD' end
  local parents = vim.split(vim.trim(M.run(root, { 'rev-list', '--parents', '-n', '1', commit })), ' ', { plain = true })
  return parents[2] or empty_tree(root)
end
function M.run(root, args, input)
  assert(root, 'Not in a Git repository')
  local argv = { 'git', '--no-pager', '-C', root }
  vim.list_extend(argv, args)
  local r = vim.system(argv, { stdin = input }):wait()
  if r.code ~= 0 then error(vim.trim(r.stderr or 'Git failed'), 0) end
  return r.stdout or ''
end
function M.context(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local root = assert(utils.get_buf_work_tree(buf), 'Not in a Git repository')
  local source = vim.b[buf].git_object or vim.b[buf].lazyagent_note_source
  local name = vim.api.nvim_buf_get_name(buf)
  local path = source and source.path
  if not path and name:sub(1, #root + 1) == root .. '/' then path = name:sub(#root + 2) end
  return root, path, source
end
-- Match Git's path encoding: keep directory separators and ordinary
-- characters readable, escaping only URI delimiters, percent and controls.
local function encode_path(path)
  return (path:gsub('[%%#?%c]', function(c) return ('%%%02X'):format(c:byte()) end))
end
function M.uri(root, object)
  local stage, path = object:match('^:([0-3]):(.*)$')
  local revision
  if stage then revision = stage else revision, path = object:match('^(.-):(.*)$') end
  local tail = path and (vim.uri_encode(revision, 'rfc2396') .. '/' .. encode_path(path)) or vim.uri_encode(object, 'rfc2396')
  return 'git-object://' .. encode_path(root) .. '//' .. tail
end
local function decode(name)
  local root, object = name:match('^git%-object://(.-)//(.*)$')
  assert(root, 'Invalid Git object URI')
  local revision, path = object:match('^([^/]+)/(.*)$')
  if revision then
    revision, path = vim.uri_decode(revision), vim.uri_decode(path)
    object = revision:match('^[0-3]$') and (':' .. revision .. ':' .. path) or (revision .. ':' .. path)
  else
    -- The original fully escaped URI has no literal slash in its object part.
    -- Keep it readable from existing jump lists, sessions and quickfix entries.
    object = vim.uri_decode(object)
  end
  return vim.uri_decode(root), object
end
-- Expand buffer references to repository paths rather than encoded URI names.
function M.expand(arg, buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if arg == '<cfile>' then arg = vim.fn.expand('<cfile>') end
  return (arg:gsub('([%%#])(%d*)', function(mark, number)
    local target = mark == '%' and buf or (number ~= '' and tonumber(number) or vim.fn.bufnr('#'))
    assert(target and target > 0 and vim.api.nvim_buf_is_valid(target), 'No referenced buffer')
    local _, path = M.context(target)
    return assert(path, 'No referenced file')
  end))
end
function M.file_path(root, path, base)
  if path:sub(1, 1) == '/' then return vim.fs.normalize(path) end
  if path:match('^%.%.?[/\\]') then base = base or vim.fn.getcwd() end
  return vim.fs.normalize((base or root) .. '/' .. path)
end
function M.resolve(arg, buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local root, path, source = M.context(buf)
  if arg == '' or arg == '>:' then
    if not path then return root, ':', source, 'status' end
    return root, source and root .. '/' .. path or ':0:' .. path, source, source and 'file' or 'object'
  end
  if arg == ':' then return root, ':', source, 'status' end
  if arg == ':/' then return root, root .. '/' .. assert(path, 'No current file'), source, 'file' end
  if arg == '%' or arg:match('^#%d*$') then
    local target = arg == '%' and buf or (tonumber(arg:sub(2)) or vim.fn.bufnr('#'))
    local _, target_path, target_source = M.context(target)
    return root, target_source and target_source.object or root .. '/' .. assert(target_path, 'No referenced file'),
      source, target_source and 'object' or 'file'
  end
  arg = M.expand(arg, buf)
  arg = arg:gsub('!(%d*)', function(number)
    local target = number ~= '' and tonumber(number) or buf
    local owner = vim.b[target].git_commit or (vim.b[target].git_object or {}).revision
    return owner or 'HEAD'
  end)
  if arg:sub(1, 1) == '/' or arg:match('^%.%.?[/\\]') or arg:match('^:%(top') or arg:match('^:%(literal%)') then
    local top = arg:match('^:%([^)]*top[^)]*%)')
    arg = arg:gsub('^:%([^)]*%)', '')
    return root, M.file_path(root, arg, top and root or nil), source, 'file'
  end
  -- Git's >~1 form follows the current file through a relative commit.
  -- Accept the shorter ~1 spelling as well; from a commit view there is no
  -- file path, so the same spelling opens the relative commit itself.
  local shorthand = arg:sub(1, 1) == '>' and arg:sub(2) or arg
  local relative, suffix = shorthand:match('^([~^]%d*)(:.*)$')
  if not relative and shorthand:match('^[~^]%d*$') then relative = shorthand end
  if relative then
    local revision = vim.b[buf].git_commit or (source and source.revision)
    if not (type(revision) == 'string' and revision:match('^%x%x%x%x%x%x%x+$')) then revision = 'HEAD' end
    if suffix == ':%' then suffix = ':' .. assert(path, 'No current file') end
    arg = revision .. relative .. (suffix or (path and ':' .. path or ''))
  end
  if arg:match('^:[0-3]$') then arg = arg .. ':' .. assert(path, 'No current file') end
  if arg:sub(-2) == ':%' then arg = arg:sub(1, -2) .. assert(path, 'No current file') end
  if arg:sub(1, 1) == ':' and not arg:match('^:[0-3]:') then arg = ':0:' .. arg:sub(2) end
  if not arg:find(':', 1, true) then
    local left, right = arg:match('^(.-)%.%.%.(.-)$')
    if left then arg = vim.trim(M.run(root, { 'merge-base', left ~= '' and left or 'HEAD', right ~= '' and right or 'HEAD' })) end
    local ok = pcall(M.run, root, { 'rev-parse', '--verify', '--end-of-options', arg })
    if not ok then return root, M.file_path(root, arg, root), source, 'file' end
  end
  return root, arg, source, 'object'
end
function M.read(root, object, kind)
  if kind == 'file' then
    local file = assert(io.open(object, 'rb'), 'Cannot read file: ' .. object)
    local content = file:read('*a'); file:close(); return content
  end
  assert(kind ~= 'status', 'Cannot read a status panel as text')
  return M.run(root, { 'show', object })
end
-- Keep writable index buffers consistent after commands that stage their text.
function M.index_written(buf)
  local source = vim.b[buf].git_object
  if not source or source.stage ~= '0' then return end
  source.blob = vim.trim(M.run(source.root, { 'rev-parse', '--verify', source.object }))
  vim.b[buf].git_object = source
  local note = vim.b[buf].lazyagent_note_source
  if note then note.blob = source.blob; vim.b[buf].lazyagent_note_source = note end
  vim.bo[buf].modified = false
end
function M.load(buf, root, object)
  local stage, path = object:match('^:([0-3]):(.*)$')
  local rev
  if not stage then rev, path = object:match('^(.-):(.*)$') end
  local oid = vim.trim(M.run(root, { 'rev-parse', '--verify', '--end-of-options', object }))
  local kind = vim.trim(M.run(root, { 'cat-file', '-t', oid }))
  assert(kind == 'blob' or kind == 'tree', 'Use Gedit for commit objects')
  local content = M.run(root, kind == 'tree' and { 'ls-tree', oid } or { 'cat-file', 'blob', oid })
  assert(not content:find('\0', 1, true), 'Binary Git objects cannot be edited as text')
  local lines = vim.split(content, '\n', { plain = true })
  local eol = content:sub(-1) == '\n'
  if eol then table.remove(lines) end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  utils.set_buf_work_tree(buf, root)
  vim.b[buf].git_object = { root = root, object = object, path = path, revision = rev, stage = stage, blob = oid }
  vim.b[buf].lazyagent_note_source = { kind = 'git', root = root, git_dir = utils.get_git_dir(root), path = path,
    revision = rev or 'blob', blob = oid }
  vim.bo[buf].buftype, vim.bo[buf].bufhidden = 'acwrite', 'hide'
  vim.bo[buf].endofline, vim.bo[buf].fixendofline = eol, false
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = kind == 'tree' and 'git' or path and (vim.filetype.match({ filename = path }) or '') or 'git'
  vim.bo[buf].readonly, vim.bo[buf].modifiable = stage ~= '0', stage == '0'
  vim.bo[buf].modified = false
  if kind == 'blob' then M.attach_gitsigns(buf, root, path, comparison_base(root, rev, stage)) end
  if kind == 'tree' then
    vim.keymap.set('n', '<CR>', function()
      local entry = vim.api.nvim_get_current_line():match('^%d+ %w+ %x+\t(.*)$')
      if not entry then return end
      local prefix = object:sub(-1) == ':' and object or object .. (object:find(':', 1, true) and '/' or ':')
      M.open(prefix .. entry, 'edit', root)
    end, { buffer = buf, silent = true })
  end
end
function M.write(buf)
  local s = assert(vim.b[buf].git_object, 'Not a Git object')
  assert(s.stage == '0', 'Only stage 0 index buffers are writable')
  local entry = M.run(s.root, { 'ls-files', '--stage', '-z', '--', s.path })
  local mode, current = entry:match('^(%d+) (%x+) 0\t')
  assert(mode and current == s.blob, 'Index changed; reload before writing')
  local content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
  if vim.bo[buf].endofline then content = content .. '\n' end
  local oid = vim.trim(M.run(s.root, { 'hash-object', '-w', '--stdin' }, content))
  M.run(s.root, { 'update-index', '--cacheinfo', mode, oid, s.path })
  s.blob = oid; vim.b[buf].git_object = s
  local source = vim.b[buf].lazyagent_note_source; source.blob = oid; vim.b[buf].lazyagent_note_source = source
  vim.bo[buf].modified = false
  utils.fire_git_changed({ work_tree = s.root })
end
function M.open(arg, command, root)
  local object, kind, source
  if root then object, kind = arg, arg:sub(1, 1) == '/' and 'file' or 'object'
  else root, object, source, kind = M.resolve(arg or '') end
  if kind == 'status' then return require('git.features.status').open({ split = command ~= 'edit' }) end
  if kind == 'file' then
    vim.cmd((command or 'edit') .. ' ' .. vim.fn.fnameescape(object))
    return vim.fn.bufnr(object)
  end
  -- cat-file reports the missing revision/path, unlike rev-parse's generic
  -- "Needed a single revision" for a valid branch lacking the requested file.
  local ok; ok, kind = pcall(M.run, root, { 'cat-file', '-t', object })
  if not ok then error(("Cannot open Git object '%s'\nRepository: %s\n%s"):format(object, root, kind), 0) end
  kind = vim.trim(kind)
  local oid = vim.trim(M.run(root, { 'rev-parse', '--verify', '--end-of-options', object }))
  if kind == 'tag' then
    oid = vim.trim(M.run(root, { 'rev-parse', '--verify', '--end-of-options', object .. '^{}' }))
    kind = vim.trim(M.run(root, { 'cat-file', '-t', oid }))
  end
  if kind == 'commit' then
    local name = require('git.buffer_names').commit(root, oid)
    vim.cmd((command or 'edit') .. ' ' .. vim.fn.fnameescape(name))
    return vim.fn.bufnr(name)
  end
  if kind == 'blob' and not object:match('^:[0-3]:') then
    local rev, path = object:match('^(.-):(.*)$')
    if rev then
      local ok, commit = pcall(M.run, root, { 'rev-parse', '--verify', '--end-of-options', rev .. '^{commit}' })
      if ok then object = vim.trim(commit) .. ':' .. path end
    end
  end
  local name = M.uri(root, object)
  vim.cmd((command or 'edit') .. ' ' .. vim.fn.fnameescape(name))
  return vim.fn.bufnr(name)
end
function M.setup(group)
  vim.api.nvim_create_autocmd('BufReadCmd', { group = group, pattern = 'git-object://*', callback = function(ev)
    local root, object = decode(ev.match); M.load(ev.buf, root, object)
  end })
  vim.api.nvim_create_autocmd('BufWriteCmd', { group = group, pattern = 'git-object://*', callback = function(ev) M.write(ev.buf) end })
end
return M
