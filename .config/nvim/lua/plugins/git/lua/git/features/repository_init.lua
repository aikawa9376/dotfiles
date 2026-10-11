-- Repository setup works before a worktree exists; never resolve the target via gh.
local M = {}
local async = require('git.features.async')
local utils = require('git.utils')
local files = {}

local function fail(message) error(message, 0) end
local function checked(root, args)
  local output, err = async.git(root, args)
  if not output then fail(err) end
  return vim.trim(output)
end

local function origin(root)
  for name in checked(root, { 'remote' }):gmatch('[^\r\n]+') do
    if name == 'origin' then return checked(root, { 'remote', 'get-url', 'origin' }) end
  end
end

-- Resolve through the nearest existing ancestor, including paths yet to be created.
local function target(path, base)
  if path:find('[\r\n]') then fail('Directory cannot contain newlines') end
  if path:sub(1, 1) == '~' then path = vim.fn.expand(path) end
  if not vim.startswith(path, '/') then path = base .. '/' .. path end
  path = vim.fs.normalize(path)
  local ancestor, suffix = path, {}
  while not vim.uv.fs_lstat(ancestor) do
    local parent = vim.fs.dirname(ancestor)
    if not parent or parent == ancestor then fail('Cannot resolve directory: ' .. path) end
    table.insert(suffix, 1, vim.fs.basename(ancestor))
    ancestor = parent
  end
  local stat = vim.uv.fs_stat(ancestor)
  if not stat or stat.type ~= 'directory' then fail('Not a directory: ' .. ancestor) end
  ancestor = assert(vim.uv.fs_realpath(ancestor))
  return #suffix > 0 and vim.fs.joinpath(ancestor, table.concat(suffix, '/')) or ancestor, ancestor
end

local function inspect(path, base)
  local root, ancestor = target(path, base)
  local bare = async.git(ancestor, { 'rev-parse', '--is-bare-repository' })
  if bare and vim.trim(bare) == 'true' then fail('Repository setup requires a working directory, not a bare repository') end
  local enclosing = async.git(ancestor, { 'rev-parse', '--show-toplevel' })
  enclosing = enclosing and (vim.uv.fs_realpath(vim.trim(enclosing)) or vim.trim(enclosing))
  local git_dir = enclosing and checked(ancestor, { 'rev-parse', '--absolute-git-dir' }) or nil
  return { root = root, enclosing = enclosing, git_dir = git_dir,
    origin = enclosing == root and origin(root) or nil }
end

local function defaults(root, repo_name)
  return vim.tbl_extend('force', {
    ['README.md'] = { '# ' .. vim.fs.basename(repo_name or root), '' },
    ['.gitignore'] = { '# Editor and OS files', '*.swp', '*.swo', '*~', '.DS_Store', 'Thumbs.db',
      '', '# Local environment', '.env', '.env.*', '!.env.example', '!.env.sample' },
  }, files)
end

local function write_defaults(root, repo_name)
  local skipped = {}
  for _, name in ipairs({ 'README.md', '.gitignore' }) do
    local content = defaults(root, repo_name)[name]
    local fd, err, code = vim.uv.fs_open(root .. '/' .. name, 'wx', 420)
    if fd then
      local bytes = table.concat(content, '\n') .. '\n'
      local written, write_err = vim.uv.fs_write(fd, bytes, 0)
      vim.uv.fs_close(fd)
      if written ~= #bytes then fail(write_err or ('Incomplete write: ' .. name)) end
    elseif code == 'EEXIST' then skipped[#skipped + 1] = name
    else fail(err) end
  end
  return skipped
end

local function ensure_main(root)
  if async.git(root, { 'show-ref', '--verify', '--quiet', 'refs/heads/main' }) then return end
  local branch = checked(root, { 'branch', '--show-current' })
  if branch == '' then
    checked(root, { 'branch', 'main', 'HEAD' }) -- Preserve detached HEAD.
  elseif branch ~= 'main' then
    checked(root, { 'branch', '-m', 'main' }) -- An existing main is never overwritten.
  end
  if not async.git(root, { 'rev-parse', '--verify', '--quiet', 'HEAD' }) then
    -- --only + --allow-empty excludes changes already staged by the user.
    checked(root, { 'commit', '--allow-empty', '--only', '-m', 'Initial commit' })
  end
end

local function publish_main(root)
  local url = checked(root, { 'remote', 'get-url', '--push', 'origin' })
  local result = async.system(root, { 'git', 'ls-remote', '--exit-code', '--refs', '--', url, 'refs/heads/main' },
    { env = { GIT_TERMINAL_PROMPT = '0' } })
  if result.code ~= 0 and result.code ~= 2 then
    fail(vim.trim(result.stderr or '') ~= '' and vim.trim(result.stderr) or 'Cannot inspect origin/main')
  end
  local remote = async.git(root, { 'config', '--get', 'branch.main.remote' })
  local merge = async.git(root, { 'config', '--get', 'branch.main.merge' })
  remote, merge = remote and vim.trim(remote), merge and vim.trim(merge)
  local may_set_upstream = (not remote or remote == 'origin') and (not merge or merge == 'refs/heads/main')
  if result.code == 2 then
    local args = { 'push' }
    if may_set_upstream then args[#args + 1] = '-u' end
    vim.list_extend(args, { 'origin', 'main' })
    local output, err = async.git(root, args, { env = { GIT_TERMINAL_PROMPT = '0' } })
    if not output then fail(err .. '\nRetry initial push through Repository setup (p)') end
  elseif may_set_upstream and (not remote or not merge) then
    -- The remote branch already exists: fetch only to make tracking resolvable,
    -- then configure upstream without publishing any newer local commits.
    checked(root, { 'fetch', '--no-tags', '--', url, '+refs/heads/main:refs/remotes/origin/main' })
    checked(root, { 'branch', '--set-upstream-to=origin/main', 'main' })
  end
end

local function execute(mode, plan, github_opts)
  local initialized = false
  local task, err = async.run(plan.root, function()
    local current = inspect(plan.root, plan.root)
    if not vim.deep_equal(current, plan) then fail('Repository changed while choosing setup options; reopen Repository setup') end
    if mode == 'publish' and (current.enclosing ~= plan.root or not current.origin) then
      fail('Initial push requires an existing repository with origin; use GitHub setup (g) to create one')
    end
    if mode == 'github' and not current.origin then
      require('git.features.github').command({ root = select(2, target(plan.root, plan.root)) }, { 'api', 'user', '--jq', '.login' })
      if not vim.deep_equal(inspect(plan.root, plan.root), plan) then fail('Repository changed during authentication; reopen Repository setup') end
    end
    if vim.fn.mkdir(plan.root, 'p') == 0 and vim.fn.isdirectory(plan.root) ~= 1 then fail('Cannot create directory: ' .. plan.root) end
    if current.enclosing ~= plan.root then checked(plan.root, { 'init' }) end
    initialized = true
    local skipped = (mode == 'defaults' or mode == 'github') and write_defaults(plan.root, github_opts and github_opts.name) or {}
    if mode == 'github' or mode == 'publish' then ensure_main(plan.root) end
    if (mode == 'github' or mode == 'publish') and current.origin and origin(plan.root) ~= current.origin then
      fail('Remote origin changed during setup; reopen Repository setup')
    end
    if mode == 'github' and not current.origin then
      if origin(plan.root) then fail('Remote origin changed during setup; reopen Repository setup') end
      require('git.features.github').command({ root = plan.root }, {
        'repo', 'create', github_opts.name, '--' .. github_opts.visibility,
        '--source', plan.root, '--remote', 'origin',
      })
    end
    if mode == 'github' or mode == 'publish' then publish_main(plan.root) end
    return skipped
  end, function(ok, result)
    if initialized then
      utils.fire_git_changed({ work_tree = plan.root })
      require('git.features.status').open({ work_tree = plan.root, split = true })
    end
    if not ok then
      vim.notify(tostring(result) .. (initialized and ('\nLocal repository retained at ' .. plan.root) or ''), vim.log.levels.ERROR)
    else
      vim.notify('Repository ready: ' .. plan.root .. (#result > 0 and ('\nKept existing: ' .. table.concat(result, ', ')) or ''))
    end
  end, { mutation = true })
  if not task then vim.notify(err, vim.log.levels.WARN) end
  return task
end

local function github_options(plan)
  vim.ui.input({ prompt = 'GitHub repository (name or OWNER/name): ', default = vim.fs.basename(plan.root) }, function(name)
    if not name then return end
    name = vim.trim(name)
    if not (name:match('^[%w_.%-]+$') or name:match('^[%w_.%-]+/[%w_.%-]+$')) or name:sub(1, 1) == '-'
      or name == '.' or name == '..' then
      vim.notify('Invalid GitHub repository name', vim.log.levels.ERROR); return
    end
    vim.ui.select({ 'private', 'public' }, {
      prompt = 'Create GitHub repository ' .. name .. ' and initial push (main) — visibility:',
    }, function(visibility)
      if visibility then execute('github', plan, { name = name, visibility = visibility }) end
    end)
  end)
end

function M.start(mode, opts)
  opts = opts or {}
  assert(vim.tbl_contains({ 'plain', 'defaults', 'github', 'publish' }, mode), 'Invalid repository setup mode')
  local base = opts.base or vim.fn.getcwd()
  local function choose(path)
    if not path or vim.trim(path) == '' then return end
    async.run(base, function() return inspect(path, base) end, function(ok, plan)
      if not ok then vim.notify(tostring(plan), vim.log.levels.ERROR); return end
      local function proceed()
        if mode == 'github' and not plan.origin then github_options(plan) else execute(mode, plan) end
      end
      if plan.enclosing and plan.enclosing ~= plan.root then
        local message = 'Create nested repository at ' .. plan.root .. ' inside ' .. plan.enclosing .. '?'
        vim.ui.select({ 'Cancel', 'Continue' }, { prompt = message }, function(choice)
          if choice == 'Continue' then proceed() end
        end)
      else proceed() end
    end)
  end
  if opts.path then choose(opts.path)
  else vim.ui.input({ prompt = 'Repository directory: ', default = base, completion = 'dir' }, choose) end
end

function M.open(opts)
  opts = opts or {}
  local base = opts.base or vim.fn.getcwd()
  return require('git.features.transient_menu').show({ kind = 'repository-init', title = 'Repository setup',
    context = 'Directory: ' .. base, groups = { { title = 'Initialize', actions = {
      { key = 'i', label = 'Git init', run = function() M.start('plain', { base = base, path = opts.path }) end },
      { key = 'd', label = 'Init with README and gitignore', run = function() M.start('defaults', { base = base, path = opts.path }) end },
      { key = 'g', label = 'GitHub setup and initial push (main)', run = function() M.start('github', { base = base, path = opts.path }) end },
      { key = 'p', label = 'Initial push to existing origin (main)', run = function() M.start('publish', { base = base, path = opts.path }) end },
    } } } })
end

function M.setup(opts)
  files = vim.deepcopy((opts or {}).files or {})
  for name, content in pairs(files) do
    assert(name == 'README.md' or name == '.gitignore', 'Only README.md and .gitignore templates are supported')
    assert(type(content) == 'table' and vim.islist(content), 'Repository templates must be lists of lines')
    for _, line in ipairs(content) do
      assert(type(line) == 'string' and not line:find('[\r\n]'), 'Repository templates must contain individual text lines')
    end
  end
  vim.api.nvim_create_user_command('GitInit', function(args)
    local parsed = require('git.commands').argv(args.args)
    M.open({ path = #parsed == 1 and parsed[1] or args.args ~= '' and args.args or nil })
  end, { nargs = '?', complete = 'dir', desc = 'Initialize a repository, default files, or GitHub remote' })
end

return M
