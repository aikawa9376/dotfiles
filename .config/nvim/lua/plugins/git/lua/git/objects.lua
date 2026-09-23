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
-- Match Fugitive's path encoding: keep directory separators and ordinary
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
function M.resolve(arg, buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local root, path, source = M.context(buf)
  -- Fugitive's >~1 form follows the current file through a relative commit.
  -- Accept the shorter ~1 spelling as well; from a commit view there is no
  -- file path, so the same spelling opens the relative commit itself.
  local shorthand = arg:sub(1, 1) == '>' and arg:sub(2) or arg
  local relative, suffix = shorthand:match('^([~^]%d*)(:.*)$')
  if not relative and shorthand:match('^[~^]%d*$') then relative = shorthand end
  if relative then
    local revision = vim.b[buf].fugitive_commit or (source and source.revision)
    if not (type(revision) == 'string' and revision:match('^%x%x%x%x%x%x%x+$')) then revision = 'HEAD' end
    if suffix == ':%' then suffix = ':' .. assert(path, 'No current file') end
    arg = revision .. relative .. (suffix or (path and ':' .. path or ''))
  end
  if arg == '' then arg = ':0:' .. assert(path, 'No current file') end
  if arg == '%' then arg = 'HEAD:' .. assert(path, 'No current file') end
  if arg:match('^:[0-3]$') then arg = arg .. ':' .. assert(path, 'No current file') end
  if arg == ':' then arg = ':0:' .. assert(path, 'No current file') end
  if arg:sub(-2) == ':%' then arg = arg:sub(1, -2) .. assert(path, 'No current file') end
  if arg:sub(1, 1) == ':' and not arg:match('^:[0-3]:') then arg = ':0:' .. arg:sub(2) end
  return root, arg, source
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
  vim.b[buf].lazyagent_note_source = { kind = 'fugitive', root = root, git_dir = utils.get_git_dir(root), path = path,
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
  utils.fire_fugitive_changed({ work_tree = s.root })
end
function M.open(arg, command, root)
  local object
  if root then object = arg else root, object = M.resolve(arg or '') end
  -- cat-file reports the missing revision/path, unlike rev-parse's generic
  -- "Needed a single revision" for a valid branch lacking the requested file.
  local ok, kind = pcall(M.run, root, { 'cat-file', '-t', object })
  if not ok then error(("Cannot open Git object '%s'\nRepository: %s\n%s"):format(object, root, kind), 0) end
  kind = vim.trim(kind)
  local oid = vim.trim(M.run(root, { 'rev-parse', '--verify', '--end-of-options', object }))
  if kind == 'tag' then
    oid = vim.trim(M.run(root, { 'rev-parse', '--verify', '--end-of-options', object .. '^{}' }))
    kind = vim.trim(M.run(root, { 'cat-file', '-t', oid }))
  end
  if kind == 'commit' then
    if command == 'vsplit' then vim.cmd('vsplit') end
    return require('git.features.commit').open({ work_tree = root, revision = oid,
      tab = command == 'tabedit', split = command == 'split' })
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
  return vim.api.nvim_get_current_buf()
end
function M.setup(group)
  vim.api.nvim_create_autocmd('BufReadCmd', { group = group, pattern = 'git-object://*', callback = function(ev)
    local root, object = decode(ev.match); M.load(ev.buf, root, object)
  end })
  vim.api.nvim_create_autocmd('BufWriteCmd', { group = group, pattern = 'git-object://*', callback = function(ev) M.write(ev.buf) end })
end
return M
