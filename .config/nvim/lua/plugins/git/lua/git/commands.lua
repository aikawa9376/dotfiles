local M = {}
local objects = require('git.objects')
local utils = require('git.utils')
-- Parse arguments without invoking a shell (quotes and escaped spaces included).
function M.argv(text)
  local result, word, quote, escaped, active = {}, '', nil, false, false
  for i = 1, #text do
    local c = text:sub(i, i)
    if escaped then word, escaped = word .. c, false
    elseif c == '\\' and quote ~= "'" then escaped, active = true, true
    elseif quote then if c == quote then quote = nil else word = word .. c end
    elseif c == '"' or c == "'" then quote, active = c, true
    elseif c:match('%s') then
      if active then result[#result + 1], word, active = word, '', false end
    else word, active = word .. c, true end
  end
  assert(not quote and not escaped, 'Unclosed quote or escape')
  if active then result[#result + 1] = word end
  return result
end
local function output(root, args, content)
  vim.cmd('botright new')
  local b = vim.api.nvim_get_current_buf()
  utils.set_buf_work_tree(b, root)
  vim.bo[b].buftype, vim.bo[b].bufhidden, vim.bo[b].swapfile = 'nofile', 'wipe', false
  vim.api.nvim_buf_set_lines(b, 0, -1, false, vim.split(content:gsub('\n$', ''), '\n', { plain = true }))
  vim.bo[b].filetype, vim.bo[b].modifiable = 'git', false
  vim.b[b].git_command = args
  vim.keymap.set('n', 'q', '<cmd>close<CR>', { buffer = b, silent = true })
  return b
end
local function error_output(lines, code)
  local last = {}
  for _, line in ipairs(lines or {}) do
    line = vim.trim(line:gsub('\27%[[0-9;]*[A-Za-z]', ''))
    if line ~= '' then
      last[#last + 1] = line
      if #last > 8 then table.remove(last, 1) end
    end
  end
  return #last > 0 and table.concat(last, '\n') or ('Git exited with status ' .. code)
end

local function background(root, args)
  local argv = { 'git', '-C', root }; vim.list_extend(argv, args)
  local lines = {}
  local function collect(_, data)
    for _, line in ipairs(data or {}) do if line ~= '' then lines[#lines + 1] = line end end
  end
  local job = vim.fn.jobstart(argv, {
    env = require('git.editor').environment(),
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = collect,
    on_stderr = collect,
    on_exit = function(_, code)
      vim.schedule(function()
        utils.fire_fugitive_changed({ work_tree = root })
        if code ~= 0 then vim.notify(error_output(lines, code), vim.log.levels.ERROR) end
      end)
    end,
  })
  if job <= 0 then vim.notify('Could not start Git', vim.log.levels.ERROR) end
  return job
end

local function terminal(root, args, keep_open)
  local source_win = vim.api.nvim_get_current_win()
  vim.cmd('botright new')
  local b = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  utils.set_buf_work_tree(b, root)
  vim.bo[b].bufhidden = 'wipe'
  local argv = { 'git', '-C', root }; vim.list_extend(argv, args)
  local env = require('git.editor').environment()
  vim.fn.jobstart(argv, { term = true, env = env, on_exit = function(_, code)
    vim.schedule(function()
      utils.fire_fugitive_changed({ work_tree = root })
      if code ~= 0 then
        local lines = vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_lines(b, 0, -1, false) or {}
        vim.notify(error_output(lines, code), vim.log.levels.ERROR)
      end
      if not keep_open and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == b then
        if #vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(win)) > 1 then
          local focused = vim.api.nvim_get_current_win() == win
          vim.api.nvim_win_close(win, true)
          if focused and vim.api.nvim_win_is_valid(source_win) then vim.api.nvim_set_current_win(source_win) end
        end
      end
    end)
  end })
  vim.cmd('startinsert')
end

local function from_panel(bufnr)
  local filetype = vim.bo[bufnr].filetype
  return filetype:match('^fugitive') ~= nil
    or (vim.bo[bufnr].buftype == 'nofile' and vim.b[bufnr].fugitive_work_tree ~= nil)
end

local function mutates_repository(args)
  local sub = args[1]
  if vim.tbl_contains({ 'add', 'am', 'apply', 'checkout', 'clean', 'commit', 'fetch', 'merge',
    'mv', 'pull', 'push', 'rebase', 'reset', 'restore', 'revert', 'rm', 'switch', 'update-index' }, sub)
  then return true end
  if sub == 'stash' then return not vim.tbl_contains({ 'list', 'show' }, args[2]) end
  if sub == 'worktree' then return args[2] ~= 'list' end
  if sub == 'branch' then
    if #args == 1 then return false end
    for _, arg in ipairs(args) do
      if vim.tbl_contains({ '-d', '-D', '-m', '-M', '-c', '-C', '-f', '--delete', '--move',
        '--copy', '--force', '--set-upstream-to', '--unset-upstream', '--track', '--no-track' }, arg)
        or arg:match('^%-%-set%-upstream%-to=')
      then return true end
    end
    return args[2]:sub(1, 1) ~= '-'
  end
  if sub == 'tag' then
    if #args == 1 then return false end
    return not vim.tbl_contains({ '-l', '--list', '-n', '--contains', '--points-at' }, args[2])
  end
  if sub == 'remote' then return vim.tbl_contains({ 'add', 'remove', 'rename', 'set-url', 'set-head', 'prune', 'update' }, args[2]) end
  return false
end
function M.git(opts)
  local root, path = objects.context()
  local args = M.argv(opts.args)
  for i, arg in ipairs(args) do if arg == '%' then args[i] = assert(path, 'No current file') end end
  if #args == 0 or (#args == 1 and args[1] == 'status') then return require('git.features.status').open({ split = true }) end
  if #args == 1 and args[1] == 'blame' then return require('git.features.blame').open() end
  -- A terminal preserves prompts, signing, hooks and Git's editor protocol.
  local sub = args[1]
  local explicit_message = vim.tbl_contains(args, '--no-edit') or vim.tbl_contains(args, '-m') or vim.tbl_contains(args, '--message') or vim.tbl_contains(args, '-F')
  if sub == 'commit' and not explicit_message or sub == 'merge' or sub == 'rebase' or sub == 'cherry-pick' or sub == 'revert'
    or sub == 'push' or sub == 'pull' or sub == 'fetch' or sub == 'add' and vim.tbl_contains(args, '-p')
    or sub == '-c' then
    local patch_prompt = (sub == 'add' or sub == 'reset' or sub == 'restore')
      and (vim.tbl_contains(args, '-p') or vim.tbl_contains(args, '--patch'))
    if from_panel(vim.api.nvim_get_current_buf()) and not opts.bang and not patch_prompt then
      return background(root, args)
    end
    return terminal(root, args, opts.bang)
  end
  local ok, content = pcall(objects.run, root, args)
  if not ok then vim.notify(content, vim.log.levels.ERROR); return end
  local mutation = mutates_repository(args)
  if mutation then utils.fire_fugitive_changed({ work_tree = root }) end
  if opts.bang then if content ~= '' then vim.notify(vim.trim(content)) end
  elseif not mutation and content ~= '' then return output(root, args, content) end
end
function M.diff(opts, vertical)
  local root, path, source = objects.context()
  local args = M.argv(opts.args); assert(#args <= 1, 'Expected one revision or object')
  opts = vim.tbl_extend('force', opts, { args = args[1] or '' })
  assert(path, 'No current file')
  if opts.args ~= '' then
    local _, resolved = objects.resolve(opts.args)
    opts.args = resolved
  end
  local original = vim.api.nvim_get_current_win()
  if opts.args == '' and source and source.stage then
    vim.cmd((vertical and 'leftabove vsplit ' or 'leftabove split ') .. vim.fn.fnameescape(root .. '/' .. path))
    vim.cmd('diffthis'); vim.api.nvim_set_current_win(original); vim.cmd('diffthis'); return
  end
  local targets = {}
  if opts.bang then
    local unmerged = objects.run(root, { 'ls-files', '-u', '--', path })
    if unmerged ~= '' then
      for _, stage in ipairs({ '2', '3' }) do
        if unmerged:match(' ' .. stage .. '\t') then targets[#targets + 1] = ':' .. stage .. ':' .. path end
      end
    end
  end
  if #targets == 0 then
    local rev = opts.args ~= '' and opts.args or (source and source.revision and source.revision .. '^' or ':0')
    if rev:sub(-2) == ':%' then rev = rev:sub(1, -2) .. path end
    targets = { rev:find(':', 2, true) and rev or rev .. ':' .. path }
  end
  for _, target in ipairs(targets) do
    -- Resolve before changing the layout, so an invalid revision leaves it intact.
    objects.run(root, { 'rev-parse', '--verify', '--end-of-options', target })
    vim.api.nvim_set_current_win(original)
    objects.open(target, vertical and 'leftabove vsplit' or 'leftabove split', root)
    vim.cmd('diffthis')
  end
  vim.api.nvim_set_current_win(original); vim.cmd('diffthis')
end
local function history(opts, location)
  local root, path = objects.context()
  local args = { 'log', '--format=%H%x09%s' }
  vim.list_extend(args, M.argv(opts.args))
  if path then vim.list_extend(args, { '--', path }) end
  local rows = objects.run(root, args)
  local items = {}
  for row in rows:gmatch('[^\n]+') do
    local hash, subject = row:match('^(%x+)\t(.*)$')
    if hash then
      local name = path and objects.uri(root, hash .. ':' .. path) or ('git-commit://' .. root .. '/0/' .. hash)
      if name then items[#items + 1] = { filename = name, lnum = 1, text = hash:sub(1, 8) .. ' ' .. subject } end
    end
  end
  if location then vim.fn.setloclist(0, {}, ' ', { title = 'Git file history', items = items }); vim.cmd('lopen')
  else vim.fn.setqflist({}, ' ', { title = 'Git file history', items = items }); vim.cmd('copen') end
end
function M.setup(group)
  objects.setup(group)
  local completion = require('git.completion')
  local function command(name, fn, opts) vim.api.nvim_create_user_command(name, fn, vim.tbl_extend('force', { force = true }, opts or {})) end
  for _, name in ipairs({ 'G', 'Git' }) do command(name, M.git, { nargs = '*', bang = true, complete = completion.git }) end
  for name, layout in pairs({ Gedit = 'edit', Gsplit = 'split', Gvsplit = 'vsplit', Gtabedit = 'tabedit' }) do
    command(name, function(o)
      local args = M.argv(o.args); assert(#args <= 1, 'Expected one Git object')
      local ok, err = pcall(objects.open, args[1] or '', o.smods.vertical and layout == 'split' and 'vsplit' or layout)
      if not ok then vim.notify(tostring(err), vim.log.levels.ERROR) end
    end, { nargs = '?', complete = completion.objects })
  end
  for name, vertical in pairs({ Gdiff = true, Gdiffsplit = false, Gvdiffsplit = true, Ghdiffsplit = false }) do
    command(name, function(o) M.diff(o, vertical) end, { nargs = '?', bang = true, complete = completion.objects })
  end
  local function write(o)
    local root, path, source = objects.context()
    local args = M.argv(o.args); assert(#args <= 1, 'Expected one path')
    local target = args[1] or path
    assert(target, 'No current file; specify a destination')
    if target:sub(1, 3) == ':0:' then
      local destination = target:sub(4); if destination == '%' then destination = assert(path, 'No current file') end
      local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n') .. (vim.bo.endofline and '\n' or '')
      local mode = objects.run(root, { 'ls-files', '--stage', '--', destination }):match('^(%d+) ') or '100644'
      local oid = vim.trim(objects.run(root, { 'hash-object', '-w', '--stdin' }, text))
      objects.run(root, { 'update-index', '--add', '--cacheinfo', mode, oid, destination })
    elseif not source and not args[1] then
      vim.cmd('write' .. (o.bang and '!' or '')); objects.run(root, { 'add', '--', path })
    else
      local destination = assert(utils.worktree_relative_abs_path(root, target), 'Destination must be inside the worktree')
      local buf = vim.fn.bufadd(destination); vim.fn.bufload(buf)
      assert(o.bang or not vim.bo[buf].modified, 'Destination has unsaved changes; use Gwrite!')
      local lines, eol = vim.api.nvim_buf_get_lines(0, 0, -1, false), vim.bo.endofline
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines); vim.bo[buf].endofline = eol
      vim.api.nvim_buf_call(buf, function() vim.cmd('write' .. (o.bang and '!' or '')) end)
      objects.run(root, { 'add', '--', target })
    end
    utils.fire_fugitive_changed({ work_tree = root })
  end
  command('Gwrite', write, { nargs = '?', bang = true, complete = completion.files })
  command('Gwq', function(o) write(o); vim.cmd('quit' .. (o.bang and '!' or '')) end, { nargs = '?', bang = true, complete = completion.files })
  command('Gblame', function() require('git.features.blame').open() end)
  command('Gread', function(o)
    assert(o.range > 0 or o.bang or not vim.bo.modified, 'Unsaved changes; use Gread! to replace')
    local args = M.argv(o.args); assert(#args <= 1, 'Expected one Git object')
    local root, object = objects.resolve(args[1] or '')
    local text = objects.run(root, { 'show', object })
    assert(not text:find('\0', 1, true), 'Binary Git object')
    local lines = vim.split(text:gsub('\n$', ''), '\n', { plain = true })
    if o.range > 0 then vim.api.nvim_buf_set_lines(0, o.line2, o.line2, false, lines)
    else vim.api.nvim_buf_set_lines(0, 0, -1, false, lines) end
    vim.bo.endofline = text:sub(-1) == '\n'
  end, { nargs = '?', bang = true, range = true, complete = completion.objects })
  command('Ggraph', function(o) require('git.graph').open(nil, o.args ~= '' and o.args or nil) end, {
    nargs = '?', complete = function() return { 'native', 'flog' } end,
  })
  command('GgraphBackend', function(o) require('git.graph').select(o.args) end, {
    nargs = '?', complete = function() return { 'native', 'flog' } end,
  })
  for name, cd in pairs({ Gcd = 'cd', Glcd = 'lcd' }) do command(name, function(o)
    local root = objects.context(); vim.cmd(cd .. ' ' .. vim.fn.fnameescape(root .. (o.args ~= '' and '/' .. o.args or '')))
  end, { nargs = '?', complete = completion.dirs }) end
  command('Gclog', function(o) history(o, false) end, { nargs = '*', bang = true, complete = completion.log })
  command('Gllog', function(o) history(o, true) end, { nargs = '*', bang = true, complete = completion.log })
  command('Glog', function(o) vim.cmd('FugitiveLog ' .. o.args) end, { nargs = '*', complete = completion.log })
  for _, name in ipairs({ 'Gremove', 'Gdelete' }) do command(name, function(o)
    local root, path = objects.context(); assert(path, 'No current file')
    assert(o.bang or not vim.bo.modified, 'Unsaved changes; use Gremove!')
    local args = { 'rm' }; if o.bang then args[#args + 1] = '-f' end
    vim.list_extend(args, { '--', path }); objects.run(root, args)
    utils.fire_fugitive_changed({ work_tree = root }); vim.cmd('bdelete' .. (o.bang and '!' or ''))
  end, { bang = true }) end
  for _, name in ipairs({ 'Gmove', 'Grename' }) do command(name, function(o)
    local root, path = objects.context(); assert(path, 'No current file')
    local args = M.argv(o.args); assert(#args == 1, 'Expected one destination')
    local destination = args[1]
    local argv = { 'mv' }; if o.bang then argv[#argv + 1] = '-f' end
    vim.list_extend(argv, { '--', path, destination }); objects.run(root, argv)
    if vim.fn.isdirectory(root .. '/' .. destination) == 1 then destination = destination .. '/' .. vim.fs.basename(path) end
    vim.api.nvim_buf_set_name(0, root .. '/' .. destination)
    utils.fire_fugitive_changed({ work_tree = root })
  end, { nargs = 1, bang = true, complete = completion.files }) end
end
return M
