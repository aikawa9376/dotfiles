local M = {}
local objects, utils = require('git.objects'), require('git.utils')

local function changed(root, path)
  local has_head = pcall(objects.run, root, { 'rev-parse', '--verify', 'HEAD' })
  local diff = { 'diff', '--name-only' }
  if has_head then diff[#diff + 1] = 'HEAD' end
  vim.list_extend(diff, { '--', path })
  return objects.run(root, diff) ~= '' or objects.run(root, { 'ls-files', '--others', '--', path }) ~= ''
    or (not has_head and objects.run(root, { 'diff', '--cached', '--name-only', '--', path }) ~= '')
end
local function inside(root, path)
  assert(path:sub(1, #root + 1) == root .. '/', 'Destination must be inside the worktree')
  return path:sub(#root + 2)
end
function M.write(o)
  local root, path, source = objects.context()
  if o.args == '' and vim.bo.filetype == 'gitstatus' then
    return require('git.commands').git({ args = 'commit', bang = o.bang })
  end
  if o.args == '' and vim.fs.basename(vim.api.nvim_buf_get_name(0)) == 'COMMIT_EDITMSG' then
    vim.cmd('write' .. (o.bang and '!' or '')); vim.cmd('bdelete'); return
  end
  local args = require('git.commands').argv(o.args)
  local after = args[1] and args[1]:match('^%+(.*)')
  if after then table.remove(args, 1) end
  assert(#args <= 1, 'Expected one path')
  local target = args[1] or path
  assert(target, 'No current file; specify a destination')
  target = objects.expand(target)
  local buf = vim.api.nvim_get_current_buf()
  if target:sub(1, 3) == ':0:' or target:sub(1, 1) == ':' then
    local destination = target:match('^:0:(.*)$') or target:sub(2)
    assert(not destination:match('^[1-3]:'), 'Only stage 0 index buffers are writable')
    local content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') .. (vim.bo[buf].endofline and '\n' or '')
    local mode = objects.run(root, { 'ls-files', '--stage', '--', destination }):match('^(%d+) ') or '100644'
    local oid = vim.trim(objects.run(root, { 'hash-object', '-w', '--stdin' }, content))
    objects.run(root, { 'update-index', '--add', '--cacheinfo', mode, oid, destination })
    if source and source.stage == '0' and source.path == destination then objects.index_written(buf) end
  else
    local absolute = objects.file_path(root, target)
    local destination = inside(root, absolute)
    local same = not source and vim.api.nvim_buf_get_name(buf) == absolute
    assert(same or o.bang or not changed(root, destination), 'File has uncommitted changes; use Gwrite! to override')
    if same then vim.cmd('write' .. (o.bang and '!' or ''))
    else
      local target_buf = vim.fn.bufadd(absolute); vim.fn.bufload(target_buf)
      local lines, eol = vim.api.nvim_buf_get_lines(buf, 0, -1, false), vim.bo[buf].endofline
      vim.api.nvim_buf_set_lines(target_buf, 0, -1, false, lines); vim.bo[target_buf].endofline = eol
      vim.api.nvim_buf_call(target_buf, function() vim.cmd('write!') end)
    end
    local add = { 'add' }; if o.bang then add[#add + 1] = '-f' end
    vim.list_extend(add, { '--', destination }); objects.run(root, add)
    if source and source.stage == '0' and source.path == destination then objects.index_written(buf) end
  end
  utils.fire_git_changed({ work_tree = root })
  vim.cmd('diffupdate')
  if after and after ~= '' then vim.cmd(after) end
end
local function mutable_file()
  local root, path, source = objects.context()
  assert(path, 'No current file')
  assert(not source or source.stage == '0', 'Operation not supported for a historical or conflict buffer')
  return root, path, source
end
function M.remove(o, delete)
  local root, path, source = mutable_file()
  assert(o.bang or not vim.bo.modified, 'Unsaved changes; use ' .. o.name .. '!')
  local args = { 'rm' }
  if source then args[#args + 1] = '--cached' end
  if o.bang then args[#args + 1] = '-f' end
  vim.list_extend(args, { '--', path }); objects.run(root, args)
  utils.fire_git_changed({ work_tree = root })
  if delete then vim.cmd('bdelete' .. (o.bang and '!' or ''))
  elseif source then
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { '' }); vim.bo.modified = false
  else vim.cmd('edit!') end
end
function M.move(o, rename)
  local root, path, source = mutable_file()
  local args = require('git.commands').argv(o.args); assert(#args == 1, 'Expected one destination')
  local destination = objects.expand(args[1])
  local base = rename and vim.fs.dirname(root .. '/' .. path) or root
  if not rename and destination:match('^%.%.?[/\\]') then base = vim.fn.getcwd() end
  destination = objects.file_path(root, destination, base)
  inside(root, destination)
  local argv = { 'mv' }; if o.bang then argv[#argv + 1] = '-f' end
  vim.list_extend(argv, { '--', path, destination }); objects.run(root, argv)
  if vim.fn.isdirectory(destination) == 1 then destination = destination .. '/' .. vim.fs.basename(path) end
  if source then
    source.path, source.object = inside(root, destination), ':0:' .. inside(root, destination)
    vim.api.nvim_buf_set_name(0, objects.uri(root, source.object)); vim.b.git_object = source
    local note = vim.b.lazyagent_note_source
    if note then note.path = source.path; vim.b.lazyagent_note_source = note end
  else vim.cmd('keepalt saveas! ' .. vim.fn.fnameescape(destination)) end
  utils.fire_git_changed({ work_tree = root })
end
return M
