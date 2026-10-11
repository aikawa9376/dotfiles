local plugin = vim.fn.getcwd()
vim.opt.rtp:prepend(plugin)
local base = vim.fn.tempname() .. ' setup space'
vim.fn.mkdir(base, 'p')
local system = vim.system
local function git(root, args)
  local argv = { 'git', '-C', root }
  vim.list_extend(argv, args)
  local result = system(argv, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout or '')
end
vim.env.GIT_CONFIG_GLOBAL = base .. '/gitconfig'
vim.fn.writefile({ '[init]', '  defaultBranch = setup-test', '[user]', '  name = Test',
  '  email = test@example.invalid', '[commit]', '  gpgSign = false' }, vim.env.GIT_CONFIG_GLOBAL)
vim.env.GIT_CONFIG_NOSYSTEM = '1'
vim.cmd('cd ' .. vim.fn.fnameescape(base))
local module = require('git.features.repository_init')
module.setup()
local opened, notices, calls = {}, {}, {}
local inputs, selects = {}, {}
local create_error, auth_error, push_error, delay = false, false, false, 2
local git_calls, remotes = {}, {}
local original_status = require('git.features.status').open
require('git.features.status').open = function(opts) opened[#opened + 1] = opts.work_tree end
vim.notify = function(message) notices[#notices + 1] = tostring(message) end
vim.ui.input = function(opts, cb) inputs[#inputs + 1] = { opts = opts, cb = cb } end
vim.ui.select = function(items, opts, cb) selects[#selects + 1] = { items = items, opts = opts, cb = cb } end
vim.system = function(argv, opts, cb)
  if argv[1] ~= 'gh' then
    git_calls[#git_calls + 1] = vim.deepcopy(argv)
    if push_error and vim.tbl_contains(argv, 'push') then
      assert(cb)
      vim.defer_fn(function() cb({ code = 1, stdout = '', stderr = 'mock push failure' }) end, delay)
      return { kill = function() end }
    end
    return system(argv, opts, cb)
  end
  assert(cb, 'GitHub commands must run asynchronously')
  calls[#calls + 1] = { argv = vim.deepcopy(argv), opts = vim.deepcopy(opts) }
  local is_create = argv[2] == 'repo' and argv[3] == 'create'
  assert(is_create or (argv[2] == 'api' and argv[3] == 'user'))
  local failed = is_create and create_error or not is_create and auth_error
  vim.defer_fn(function()
    if is_create and not failed then
      local remote_path = base .. '/remote-' .. #calls .. '.git'
      git(base, { 'init', '--bare', '-q', '-b', 'main', remote_path })
      remotes[opts.cwd] = remote_path
      git(opts.cwd, { 'remote', 'add', 'origin', remote_path })
    end
    cb({ code = failed and 1 or 0, stdout = is_create and 'https://github.example.test/owner/project\n' or 'owner\n',
      stderr = failed and 'mock GitHub failure' or '' })
  end, delay)
  return { kill = function() end }
end
local function count_git(command)
  local total = 0
  for _, argv in ipairs(git_calls) do if vim.tbl_contains(argv, command) then total = total + 1 end end
  return total
end
local function wait_for(fn, message)
  assert(vim.wait(5000, fn, 10), (message or 'Timeout') .. '\n' .. table.concat(notices, '\n'))
end
local function complete(mode, path, expected_error)
  local before = #notices
  module.start(mode, { base = base, path = path })
  wait_for(function() return #notices > before end)
  local root = vim.fs.joinpath(base, path)
  wait_for(function() return not require('git.features.async').busy(root) end)
  if expected_error then assert(notices[#notices]:find(expected_error, 1, true), notices[#notices]) end
  return root
end
local plain = complete('plain', 'plain')
assert(opened[#opened] == plain and vim.fn.isdirectory(plain .. '/.git') == 1)
assert(vim.fn.filereadable(plain .. '/README.md') == 0)
assert(git(plain, { 'branch', '--show-current' }) == 'setup-test', 'init.defaultBranch ignored')
local defaults = complete('defaults', 'starter/new')
assert(vim.fn.readfile(defaults .. '/README.md')[1] == '# new')
assert(vim.tbl_contains(vim.fn.readfile(defaults .. '/.gitignore'), '!.env.example'))
assert(git(defaults, { 'diff', '--cached', '--name-only' }) == '', 'Setup staged files')
assert(git(defaults, { 'status', '--porcelain' }):find('README.md', 1, true))

-- Existing init is skipped; missing templates alone are filled, preserving symlinks.
vim.fn.writefile({ '# kept' }, defaults .. '/README.md')
local linked = base .. '/existing-ignore'
vim.fn.writefile({ 'kept-ignore' }, linked)
vim.fn.delete(defaults .. '/.gitignore')
assert(vim.uv.fs_symlink(linked, defaults .. '/.gitignore'))
local count, inits = #selects, count_git('init')
complete('defaults', 'starter/new')
assert(#selects == count and count_git('init') == inits, 'Existing repository was reinitialized')
assert(vim.fn.readfile(defaults .. '/README.md')[1] == '# kept')
assert(vim.uv.fs_lstat(defaults .. '/.gitignore').type == 'link')
assert(vim.fn.readfile(linked)[1] == 'kept-ignore')
assert(notices[#notices]:find('Kept existing:', 1, true))

count = #selects
local nested = plain .. '/nested'
module.start('plain', { base = base, path = nested })
wait_for(function() return #selects > count end)
assert(selects[#selects].opts.prompt:find('nested repository', 1, true))
selects[#selects].cb('Cancel')
assert(vim.fn.isdirectory(nested) == 0, 'Cancelled nesting changed disk')
count = #selects
module.start('plain', { base = base, path = nested })
wait_for(function() return #selects > count end)
local before = #notices; selects[#selects].cb('Continue')
wait_for(function() return #notices > before end)
assert(git(nested, { 'rev-parse', '--show-toplevel' }) == nested)

-- Menu captures cwd before it closes; subsequent prompts cannot retarget it.
local ui = module.open({ base = base, path = 'github repo' })
for _, key in ipairs({ 'i', 'd', 'g', 'p' }) do
  assert(vim.api.nvim_buf_call(ui.bufnr, function() return vim.fn.maparg(key, 'n', false, true).callback end))
end
vim.cmd('cd /tmp')
count = #inputs
vim.api.nvim_buf_call(ui.bufnr, function() vim.fn.maparg('g', 'n', false, true).callback() end)
wait_for(function() return #inputs > count end)
assert(inputs[#inputs].opts.default == 'github repo')
inputs[#inputs].cb('owner/literal-repo')
assert(selects[#selects].items[1] == 'private')
before = #notices; selects[#selects].cb('private')
wait_for(function() return #notices > before end)
local remote_root = base .. '/github repo'
assert(opened[#opened] == remote_root)
local call = calls[#calls]
assert(vim.deep_equal(call.argv, { 'gh', 'repo', 'create', 'owner/literal-repo', '--private', '--source', remote_root, '--remote', 'origin' }))
assert(call.opts.cwd == remote_root and call.opts.env.GH_PROMPT_DISABLED == '1')
assert(git(remote_root, { 'remote', 'get-url', 'origin' }) == remotes[remote_root])
assert(git(remote_root, { 'status', '--porcelain' }):find('README.md', 1, true))
assert(vim.fn.readfile(remote_root .. '/README.md')[1] == '# literal-repo')
assert(git(remote_root, { 'ls-tree', '-r', 'HEAD' }) == '', 'Initial commit contains files')
assert(git(remote_root, { 'branch', '--show-current' }) == 'main')
assert(git(remote_root, { 'rev-parse', '--abbrev-ref', 'main@{upstream}' }) == 'origin/main')
assert(git(remotes[remote_root], { 'rev-parse', 'main' }) == git(remote_root, { 'rev-parse', 'HEAD' }))

local function start_github(path)
  local n = #inputs
  module.start('github', { base = base, path = path })
  wait_for(function() return #inputs > n end)
end
start_github('cancelled')
inputs[#inputs].cb('cancelled')
selects[#selects].cb(nil)
assert(vim.fn.isdirectory(base .. '/cancelled') == 0, 'Cancelled visibility created local state')
start_github('bad-name')
before = #notices; inputs[#inputs].cb('bad $(shell)')
assert(#notices > before and vim.fn.isdirectory(base .. '/bad-name') == 0)

-- A competing init while choosing GitHub options invalidates the preflight plan.
start_github('changed')
vim.fn.mkdir(base .. '/changed', 'p'); git(base .. '/changed', { 'init', '-q' })
inputs[#inputs].cb('changed')
before = #notices; count = #calls; selects[#selects].cb('private')
wait_for(function() return #notices > before end)
assert(notices[#notices]:find('Repository changed', 1, true) and #calls == count)

-- Auth failure happens before initialization; create failure retains local setup.
auth_error = true
start_github('auth-failure'); inputs[#inputs].cb('auth-failure')
before = #notices; selects[#selects].cb('private')
wait_for(function() return #notices > before end)
assert(vim.fn.isdirectory(base .. '/auth-failure') == 0)
auth_error, create_error = false, true
start_github('create-failure'); inputs[#inputs].cb('create-failure')
before = #notices; selects[#selects].cb('public')
wait_for(function() return #notices > before end)
assert(vim.fn.filereadable(base .. '/create-failure/README.md') == 1)
assert(opened[#opened] == base .. '/create-failure' and notices[#notices]:find('Local repository retained', 1, true))
create_error = false
local failed_create_head = git(base .. '/create-failure', { 'rev-parse', 'HEAD' })
local failed_create_commits = count_git('commit')
start_github('create-failure'); inputs[#inputs].cb('create-failure')
before = #notices; selects[#selects].cb('public')
wait_for(function() return #notices > before end)
assert(count_git('commit') == failed_create_commits)
assert(git(base .. '/create-failure', { 'rev-parse', 'HEAD' }) == failed_create_head)
assert(git(remotes[base .. '/create-failure'], { 'rev-parse', 'main' }) == failed_create_head)

-- A second setup skips existing origin, history, main, remote branch and upstream.
count = #calls
local initial_head = git(remote_root, { 'rev-parse', 'HEAD' })
local commits, pushes = count_git('commit'), count_git('push')
inits = count_git('init')
complete('github', 'github repo')
assert(#calls == count and count_git('init') == inits and count_git('commit') == commits and count_git('push') == pushes)
assert(git(remote_root, { 'rev-parse', 'HEAD' }) == initial_head)

local function add_origin(root, name)
  local remote_path = base .. '/' .. name .. '.git'
  git(base, { 'init', '--bare', '-q', '-b', 'main', remote_path })
  git(root, { 'remote', 'add', 'origin', remote_path })
  return remote_path
end

-- Empty initialization excludes a preexisting index and leaves worktree edits intact.
local staged_root = base .. '/staged'
vim.fn.mkdir(staged_root, 'p'); git(staged_root, { 'init', '-q', '-b', 'old-name' })
vim.fn.writefile({ '# preserve README' }, staged_root .. '/README.md')
vim.fn.writefile({ 'staged content' }, staged_root .. '/staged.txt')
git(staged_root, { 'add', 'staged.txt' })
local index_before = git(staged_root, { 'ls-files', '--stage' })
vim.fn.writefile({ 'worktree content' }, staged_root .. '/staged.txt')
local staged_remote = add_origin(staged_root, 'staged-remote')
count = #calls; commits = count_git('commit')
complete('github', 'staged')
assert(#calls == count, 'Existing origin triggered GitHub creation/authentication')
assert(count_git('commit') == commits + 1 and git(staged_root, { 'ls-tree', '-r', 'HEAD' }) == '')
assert(git(staged_root, { 'ls-files', '--stage' }) == index_before)
assert(vim.fn.readfile(staged_root .. '/staged.txt')[1] == 'worktree content')
assert(vim.fn.readfile(staged_root .. '/README.md')[1] == '# preserve README')
assert(git(staged_root, { 'branch', '--show-current' }) == 'main')
assert(git(staged_remote, { 'rev-parse', 'main' }) == git(staged_root, { 'rev-parse', 'HEAD' }))

-- Existing main and history are kept even when setup starts on a different branch.
local existing = base .. '/existing'
vim.fn.mkdir(existing, 'p'); git(existing, { 'init', '-q', '-b', 'main' })
vim.fn.writefile({ 'base' }, existing .. '/tracked.txt')
git(existing, { 'add', 'tracked.txt' }); git(existing, { 'commit', '-qm', 'base' })
local main_before = git(existing, { 'rev-parse', 'main' })
local existing_remote = add_origin(existing, 'existing-remote')
git(existing, { 'push', 'origin', 'main' }) -- Remote main exists, but upstream is absent.
git(existing, { 'checkout', '-qb', 'feature' })
vim.fn.writefile({ 'feature' }, existing .. '/tracked.txt')
git(existing, { 'commit', '-qam', 'feature' })
vim.fn.writefile({ 'staged change' }, existing .. '/tracked.txt'); git(existing, { 'add', 'tracked.txt' })
index_before = git(existing, { 'ls-files', '--stage' })
local feature_before = git(existing, { 'rev-parse', 'HEAD' })
pushes, commits = count_git('push'), count_git('commit')
complete('publish', 'existing')
assert(count_git('push') == pushes and count_git('commit') == commits)
assert(git(existing, { 'branch', '--show-current' }) == 'feature')
assert(git(existing, { 'rev-parse', 'HEAD' }) == feature_before and git(existing, { 'rev-parse', 'main' }) == main_before)
assert(git(existing, { 'ls-files', '--stage' }) == index_before)
assert(git(existing, { 'rev-parse', '--abbrev-ref', 'main@{upstream}' }) == 'origin/main')
-- Rerunning setup does not publish new main commits after the initial branch exists.
git(existing, { 'update-ref', 'refs/heads/main', feature_before })
complete('publish', 'existing')
assert(count_git('push') == pushes and git(existing_remote, { 'rev-parse', 'main' }) == main_before)

-- Preserve an explicitly configured upstream even when origin/main is missing.
local other = base .. '/other-upstream'
vim.fn.mkdir(other, 'p'); git(other, { 'init', '-q', '-b', 'main' })
git(other, { 'commit', '--allow-empty', '-qm', 'existing history' })
local other_remote = add_origin(other, 'other-remote')
git(other, { 'remote', 'add', 'backup', other_remote })
git(other, { 'config', 'branch.main.remote', 'backup' })
git(other, { 'config', 'branch.main.merge', 'refs/heads/main' })
complete('publish', 'other-upstream')
assert(git(other, { 'config', '--get', 'branch.main.remote' }) == 'backup')
assert(git(other, { 'config', '--get', 'branch.main.merge' }) == 'refs/heads/main')
assert(git(other_remote, { 'rev-parse', 'main' }) == git(other, { 'rev-parse', 'main' }))

-- A failed push can be retried without another empty commit or GitHub repository.
push_error = true
start_github('push-failure'); inputs[#inputs].cb('push-failure')
before = #notices; selects[#selects].cb('private')
wait_for(function() return #notices > before end)
assert(notices[#notices]:find('mock push failure', 1, true))
local retry_root = base .. '/push-failure'
initial_head = git(retry_root, { 'rev-parse', 'HEAD' })
count, commits = #calls, count_git('commit')
push_error = false
complete('publish', 'push-failure')
assert(#calls == count and count_git('commit') == commits)
assert(git(retry_root, { 'rev-parse', 'HEAD' }) == initial_head)
assert(git(remotes[retry_root], { 'rev-parse', 'main' }) == initial_head)
complete('publish', 'no-origin', 'Initial push requires an existing repository with origin')
assert(vim.fn.isdirectory(base .. '/no-origin') == 0)

module.setup({ files = { ['.gitignore'] = { 'dist/' } } })
local custom = complete('defaults', 'custom')
assert(vim.deep_equal(vim.fn.readfile(custom .. '/.gitignore'), { 'dist/' }))
assert(vim.fn.readfile(custom .. '/README.md')[1] == '# custom')
vim.fn.writefile({ 'file' }, base .. '/not-directory')
complete('plain', 'not-directory/child', 'Not a directory:')

-- The Magit root exposes setup alongside its existing operation groups.
local buf = vim.api.nvim_get_current_buf()
vim.bo[buf].filetype = 'gitstatus'; vim.b[buf].git_work_tree = plain
local root_ui = require('git.features.magit_actions').open(buf)
assert(vim.api.nvim_buf_call(root_ui.bufnr, function() return vim.fn.maparg('I', 'n', false, true).callback end))
vim.api.nvim_buf_call(root_ui.bufnr, function() vim.fn.maparg('I', 'n', false, true).callback() end)
assert(vim.b.git_action_menu_kind == 'repository-init')
vim.fn.maparg('q', 'n', false, true).callback()

-- Command completion escapes spaces; its path and the actual unborn Status view work.
local command_root = base .. '/command project'
vim.cmd('GitInit ' .. vim.fn.fnameescape(command_root))
before = #notices
vim.fn.maparg('d', 'n', false, true).callback()
wait_for(function() return #notices > before end)
assert(opened[#opened] == command_root and vim.fn.filereadable(command_root .. '/README.md') == 1)
require('git.features.status').open = original_status
vim.system = system
vim.g.git_status_auto_fetch = false
package.loaded['git.features.status_watch'] = { subscribe = function() return function() end end }
package.loaded['git.features.worktree_watch'] = { subscribe = function() return function() end end }
require('git.features.status').setup(vim.api.nvim_create_augroup('RepositoryInitStatusTest', { clear = true }))
local status_buf = original_status({ work_tree = command_root, split = true })
assert(status_buf and vim.bo[status_buf].filetype == 'gitstatus')
wait_for(function()
  return table.concat(vim.api.nvim_buf_get_lines(status_buf, 0, -1, false), '\n'):find('README.md', 1, true) ~= nil
end, 'Unborn Status did not show default files')
vim.cmd('cd /tmp'); vim.fn.delete(base, 'rf')
print('PASS: idempotent setup, templates, file/index protection, empty initial commit, main, real local initial push/upstream, GitHub visibility and retry recovery')
