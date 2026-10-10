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
  utils.open_panel_split()
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
  local kind = ({ fetch = 'fetch', pull = 'pull', push = 'push' })[args[1]]
  local finish_progress = kind and require('git.features.operation_progress').start(root, kind)
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
        if finish_progress then finish_progress() end
        utils.fire_git_changed({ work_tree = root })
        if code ~= 0 then vim.notify(error_output(lines, code), vim.log.levels.ERROR) end
      end)
    end,
  })
  if job <= 0 then
    if finish_progress then finish_progress() end
    vim.notify('Could not start Git', vim.log.levels.ERROR)
  end
  return job
end

local function terminal(root, args, keep_open)
  local source_win = vim.api.nvim_get_current_win()
  utils.open_panel_split()
  local b = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  utils.set_buf_work_tree(b, root)
  vim.bo[b].bufhidden = 'wipe'
  local argv = { 'git', '-C', root }; vim.list_extend(argv, args)
  local env = require('git.editor').environment()
  vim.fn.jobstart(argv, { term = true, env = env, on_exit = function(_, code)
    vim.schedule(function()
      utils.fire_git_changed({ work_tree = root })
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
  return filetype:match('^git') ~= nil
    or (vim.bo[bufnr].buftype == 'nofile' and vim.b[bufnr].git_work_tree ~= nil)
end

local function mutates_repository(args)
  local sub = args[1]
  if sub == 'sparse-checkout' then return args[2] ~= 'list' and args[2] ~= 'check-rules' end
  if sub == 'subtree' then
    if args[2] ~= 'split' then return true end
    for _, arg in ipairs(args) do if arg == '--rejoin' or arg == '-b' or arg:match('^%-%-branch=') then return true end end
    return false
  end
  if sub == 'am' then
    for _, arg in ipairs(args) do if arg:match('^%-%-show%-current%-patch') then return false end end
    return true
  end
  if sub == 'notes' then
    for _, arg in ipairs(args) do if vim.tbl_contains({ 'add', 'append', 'copy', 'edit', 'merge', 'prune', 'remove' }, arg) then return true end end
    return false
  end
  if sub == 'bundle' then return args[2] == 'unbundle' end
  if sub == 'bisect' then return #args > 1 and args[2] ~= 'log' and args[2] ~= 'visualize' end
  if sub == 'submodule' then return vim.tbl_contains({ 'add', 'update', 'deinit', 'sync',
    'init', 'absorbgitdirs', 'set-url', 'set-branch' }, args[2]) end
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
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local root, path = objects.context(bufnr)
  local args = M.argv(opts.args)
  if require('git.features.async').busy(root) and mutates_repository(args) then
    vim.notify('A Git history operation is already running', vim.log.levels.WARN)
    return
  end
  if #args == 2 and args[1] == 'rebase' and vim.tbl_contains({ '--continue', '--skip', '--abort' }, args[2]) then
    local session = require('git.features.rebase_plan_session')
    local ok, saved = pcall(session.pending, root)
    if not ok then vim.notify(saved, vim.log.levels.WARN); return end
    if saved then return session.open(root, args[2]:sub(3)) end
  end
  for i, arg in ipairs(args) do if arg == '%' then args[i] = assert(path, 'No current file') end end
  if #args == 0 or (#args == 1 and args[1] == 'status') then
    return require('git.features.status').open({ split = not opts.bang, tab = opts.bang })
  end
  if #args == 1 and args[1] == 'blame' then return require('git.features.blame').open() end
  if #args == 3 and args[1] == 'commit' and vim.tbl_contains(args, '--amend') and vim.tbl_contains(args, '--no-edit') then
    local patch, err = require('git.features.history_rewrite').index_patch(root)
    if not patch then vim.notify(err, vim.log.levels.ERROR); return end
    if patch == '' then return end
  end
  -- A terminal preserves prompts, signing, hooks and Git's editor protocol.
  local sub = args[1]
  local explicit_message = vim.tbl_contains(args, '--no-edit') or vim.tbl_contains(args, '-m') or vim.tbl_contains(args, '--message') or vim.tbl_contains(args, '-F')
  if sub == 'commit' and not explicit_message or sub == 'merge' or sub == 'rebase' or sub == 'cherry-pick' or sub == 'revert'
    or sub == 'am' and not (args[2] or ''):match('^%-%-show%-current%-patch')
    or sub == 'subtree'
    or sub == 'push' or sub == 'pull' or sub == 'fetch' or sub == 'clone'
    or sub == 'tag' and (vim.tbl_contains(args, '--edit') or vim.tbl_contains(args, '-e'))
    or sub == 'submodule' and args[2] ~= 'status'
    or sub == 'bisect' and args[2] == 'run'
    or sub == 'add' and vim.tbl_contains(args, '-p')
    or sub == '-c' then
    local patch_prompt = (sub == 'add' or sub == 'reset' or sub == 'restore')
      and (vim.tbl_contains(args, '-p') or vim.tbl_contains(args, '--patch'))
    if from_panel(bufnr) and not opts.bang and not patch_prompt then
      return background(root, args)
    end
    return terminal(root, args, opts.bang)
  end
  local ok, content = pcall(objects.run, root, args)
  if not ok then vim.notify(content, vim.log.levels.ERROR); return end
  local mutation = mutates_repository(args)
  if mutation then utils.fire_git_changed({ work_tree = root }) end
  if opts.bang then if content ~= '' then vim.notify(vim.trim(content)) end
  elseif not mutation and content ~= '' then return output(root, args, content) end
end
function M.diff(opts, vertical)
  return require('git.diff_commands').open(opts, vertical)
end
function M.setup(group)
  objects.setup(group)
  local completion = require('git.completion')
  local files = require('git.file_commands')
  local function command(name, fn, opts)
    vim.api.nvim_create_user_command(name, fn, vim.tbl_extend('force', { force = true }, opts or {}))
  end
  for _, name in ipairs({ 'G', 'Git' }) do command(name, M.git, { nargs = '*', bang = true, complete = completion.git }) end
  for name, layout in pairs({ Gedit = 'edit', Gsplit = 'split', Gvsplit = 'vsplit', Gtabedit = 'tabedit', Gpedit = 'pedit', Gdrop = 'drop' }) do
    command(name, function(o)
      local args = M.argv(o.args)
      local after, edit_options = {}, ''
      while args[1] and args[1]:sub(1, 1) == '+' do
        local arg = table.remove(args, 1)
        if arg:sub(1, 2) == '++' then edit_options = edit_options .. ' ' .. arg
        else after[#after + 1] = arg == '+' and '$' or arg:sub(2) end
      end
      assert(#args <= 1, 'Expected one Git object')
      local cmd = o.mods ~= '' and o.mods .. ' ' or ''
      local action, size = layout, ''
      if o.range > 0 and (layout == 'split' or layout == 'vsplit') then
        action = o.count == 0 and 'edit' or layout
        size = o.count > 0 and tostring(o.count) or ''
      elseif o.range > 0 and layout == 'tabedit' then size = tostring(o.count) end
      cmd = cmd .. size .. action .. (o.bang and '!' or '') .. edit_options
      local original = vim.api.nvim_get_current_win()
      local ok, result = pcall(objects.open, args[1] or '', cmd)
      if not ok then vim.notify(tostring(result), vim.log.levels.ERROR)
      else
        if layout == 'pedit' and #after > 0 then
          for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            if vim.api.nvim_win_get_buf(win) == result then vim.api.nvim_set_current_win(win); break end
          end
        end
        for _, action in ipairs(after) do vim.cmd(action) end
        if layout == 'pedit' then vim.api.nvim_set_current_win(original) end
      end
    end, { nargs = '*', bang = true, range = (layout == 'split' or layout == 'vsplit' or layout == 'tabedit') and -1 or nil,
      addr = (layout == 'split' or layout == 'vsplit') and 'other' or (layout == 'tabedit' and 'tabs' or nil),
      complete = completion.objects })
  end
  for name, vertical in pairs({ Gdiff = true, Gvdiffsplit = true, Ghdiffsplit = false }) do
    command(name, function(o) M.diff(o, vertical) end, { nargs = '*', bang = true, complete = completion.objects })
  end
  command('Gdiffsplit', function(o) M.diff(o) end, { nargs = '*', bang = true, complete = completion.objects })
  for _, name in ipairs({ 'Gwrite', 'Gw' }) do
    command(name, files.write, { nargs = '*', bang = true, complete = completion.files })
  end
  command('Gwq', function(o) files.write(o); vim.cmd('quit' .. (o.bang and '!' or '')) end,
    { nargs = '*', bang = true, complete = completion.files })
  command('Gblame', function() require('git.features.blame').open() end)
  local function read(o)
    local args = M.argv(o.args); assert(#args <= 1, 'Expected one Git object')
    local root, object, _, kind = objects.resolve(args[1] or '')
    local text = objects.read(root, object, kind)
    assert(not text:find('\0', 1, true), 'Binary Git object')
    local lines = vim.split(text:gsub('\n$', ''), '\n', { plain = true })
    if text == '' and o.range > 0 then lines = {} end
    if o.range == 2 then vim.api.nvim_buf_set_lines(0, math.max(0, o.line1 - 1), o.line2, false, lines)
    elseif o.range > 0 then vim.api.nvim_buf_set_lines(0, o.line2, o.line2, false, lines)
    else vim.api.nvim_buf_set_lines(0, 0, -1, false, lines); vim.bo.endofline = text:sub(-1) == '\n' end
    if kind == 'object' and (vim.b.git_object or {}).object == object then
      local source = vim.b.git_object
      source.blob = vim.trim(objects.run(root, { 'rev-parse', '--verify', object })); vim.b.git_object = source
    end
    vim.cmd('diffupdate')
  end
  for _, name in ipairs({ 'Gread', 'Gr' }) do
    command(name, read, { nargs = '?', bang = true, range = -1, complete = completion.objects })
  end
  command('Ggraph', function(o) require('git.graph').open(nil, o.args ~= '' and o.args or nil) end, {
    nargs = '?', complete = function() return { 'native', 'flog' } end,
  })
  command('GgraphBackend', function(o) require('git.graph').select(o.args) end, {
    nargs = '?', complete = function() return { 'native', 'flog' } end,
  })
  for name, cd in pairs({ Gcd = 'cd', Glcd = 'lcd' }) do command(name, function(o)
    local root = objects.context()
    local parsed = M.argv(o.args)
    local arg = (#parsed == 1 and parsed[1] or o.args):gsub('^:/:?', ''):gsub('^:%([^)]*%)', '')
    local target = arg ~= '' and objects.file_path(root, arg) or root
    vim.cmd(cd .. ' ' .. vim.fn.fnameescape(target))
  end, { nargs = '?', bang = true, complete = completion.dirs }) end
  for name, location in pairs({ Gclog = false, Gllog = true }) do
    command(name, function(o) require('git.history_commands').open(o, location) end,
      { nargs = '*', bang = true, range = -1, complete = completion.log })
  end
  command('Glog', function(o) require('git.features.log').open(o) end,
    { nargs = '*', range = true, complete = completion.log })
  for name, delete in pairs({ Gremove = false, GRemove = false, GUnlink = false, Gdelete = true, GDelete = true }) do
    command(name, function(o) files.remove(o, delete) end, { bang = true })
  end
  for name, rename in pairs({ Gmove = false, GMove = false, Grename = true, GRename = true }) do
    command(name, function(o) files.move(o, rename) end,
      { nargs = 1, bang = true, complete = rename and completion.rename or completion.files })
  end
end
return M
