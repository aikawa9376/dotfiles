local M = {}
local github = require('git.features.github')
local async = require('git.features.async')
local utils = require('git.utils')
local function notify(err) vim.notify(tostring(err), vim.log.levels.ERROR) end
function M.context(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local ctx = { root = utils.get_buf_work_tree(buf) or utils.get_work_tree({}), bufnr = buf }
  local pr
  if vim.bo[buf].filetype == 'gitpr' then
    local model = require('git.features.pr').model(buf)
    if model then ctx = vim.deepcopy(model.ctx) end
  elseif vim.bo[buf].filetype == 'gitstatus' then
    pr = require('git.features.status').pull_request_at(buf, vim.fn.line('.'))
    if pr then ctx.url = pr.url end
  end
  return ctx
end
function M.run(opts, fn, callback, mutation, on_error)
  local root = opts.root or utils.get_buf_work_tree(opts.bufnr or vim.api.nvim_get_current_buf()) or utils.get_work_tree({})
  if not root then notify('Not in a Git repository'); if on_error then on_error() end; return end
  local task, err = async.run(root, function()
    local resolve_opts = vim.tbl_extend('force', opts, { root = root })
    resolve_opts.notify_change = nil
    local ctx = github.resolve(resolve_opts)
    return fn(ctx), ctx
  end, function(ok, value, ctx)
    if not ok then notify(value); if on_error then on_error(value) end; return end
    if mutation and opts.notify_change ~= false then github.changed(ctx) end
    if callback then callback(value, ctx) end
  end, { mutation = mutation == true })
  if not task then notify(err); if on_error then on_error(err) end end
  return task
end
function M.octo(ctx, review)
  local function open(pr, resolved)
    local url = pr.url or resolved.url
    vim.cmd('tabnew')
    vim.api.nvim_cmd({ cmd = 'Octo', args = { url } }, {})
    if not review then return end
    local win, started = vim.api.nvim_get_current_win(), vim.uv.hrtime()
    local function ready()
      if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_get_current_win() ~= win then return end
      local buffer = require('octo.utils').get_current_buffer()
      if buffer and buffer.ready and buffer.node and buffer:isPullRequest() then
        vim.cmd('Octo review start')
      elseif (vim.uv.hrtime() - started) / 1e9 < 15 then vim.defer_fn(ready, 50)
      else notify('Octo did not finish loading the PR') end
    end
    vim.defer_fn(ready, 50)
  end
  M.run(ctx, github.pr, open)
end
function M.create_quick(opts)
  local title_root = opts.root or utils.get_work_tree({})
  vim.ui.input({ prompt = 'PR title: ' }, function(title)
    if not title then return end
    title = vim.trim(title)
    if title == '' then notify('PR title cannot be empty'); return end
    M.run(vim.tbl_extend('force', opts, { root = title_root }), function(ctx)
      local branch, branch_err = async.git(ctx.root, { 'symbolic-ref', '--quiet', '--short', 'HEAD' })
      if not branch then error(branch_err or 'Checkout a branch before creating a PR', 0) end
      branch = vim.trim(branch)
      -- Publish using the configured push destination without force. Supplying
      -- --head then keeps gh out of its terminal-only push/fork prompts.
      local remote
      for _, key in ipairs({ 'branch.' .. branch .. '.pushRemote', 'remote.pushDefault', 'branch.' .. branch .. '.remote' }) do
        local value = async.git(ctx.root, { 'config', '--get', key })
        if value and vim.trim(value) ~= '' and vim.trim(value) ~= '.' then remote = vim.trim(value); break end
      end
      if not remote then remote = 'origin' end
      local url, remote_err = async.git(ctx.root, { 'remote', 'get-url', '--push', remote })
      if not url then error(remote_err, 0) end
      local host, repo = vim.trim(url):match('^https?://([^/]+)/(.+)$')
      if not host then host, repo = vim.trim(url):match('^ssh://[^@]+@([^/]+)/(.+)$') end
      if not host then host, repo = vim.trim(url):match('^[^@]+@([^:]+):(.+)$') end
      local head = branch
      if host and repo then
        repo = repo:gsub('%.git$', '')
        if host ~= ctx.host then error('Push remote uses another host; configure a GitHub push remote first', 0) end
        if repo ~= ctx.repo then head = repo:match('^([^/]+)/') .. ':' .. branch end
      end
      local _, push_err = async.git(ctx.root, { 'push', '--', remote, 'HEAD:refs/heads/' .. branch })
      if push_err then error(push_err, 0) end
      return github.command(ctx, { 'pr', 'create', '--repo', github.repo_arg(ctx), '--head', head, '--fill', '--title', title })
    end, function(url, ctx)
      ctx.url = vim.trim(url)
      require('git.features.pr').open(ctx)
    end, true)
  end)
end
function M.list(opts)
  M.run(opts, function(ctx)
    return github.json(ctx, { 'pr', 'list', '--repo', github.repo_arg(ctx), '--state', 'open', '--limit', '100',
      '--json', 'number,title,url,isDraft,reviewDecision,mergeable,statusCheckRollup' })
  end, function(prs, ctx)
    if #prs == 0 then vim.notify('No open pull requests'); return end
    vim.ui.select(prs, { prompt = 'Pull requests', format_item = function(pr)
      return ('#%d %s%s · %s'):format(pr.number, pr.isDraft and '[draft] ' or '', pr.title, github.summary(pr))
    end }, function(pr)
      if pr then require('git.features.pr').open({ root = ctx.root, url = pr.url }) end
    end)
  end)
end
function M.worktree(opts)
  M.run(opts, github.pr, function(pr, ctx)
    local branch = 'pr-' .. ctx.number
    local default = vim.fs.joinpath(vim.fs.dirname(ctx.root), vim.fs.basename(ctx.root) .. '-' .. branch)
    vim.ui.input({ prompt = 'PR worktree directory: ', default = default, completion = 'dir' }, function(path)
      if not path or vim.trim(path) == '' then return end
      path = require('git.features.workflow').path(ctx.root, vim.trim(path))
      M.run(ctx, function(resolved)
        -- Re-read metadata after input; never reuse a stale PR head.
        local current = github.pr(resolved)
        local _, head = require('git.features.pr_model').fetch(resolved, current)
        local exists = async.git(resolved.root, { 'show-ref', '--verify', '--quiet', 'refs/heads/' .. branch })
        if exists then error('Branch ' .. branch .. ' already exists; choose another PR worktree or remove the old branch', 0) end
        local out, err = async.git(resolved.root, { 'worktree', 'add', '-b', branch, '--', path, head })
        if not out then error(err, 0) end
        local _, config_err = async.git(resolved.root, { 'config', 'branch.' .. branch .. '.pullRequest', tostring(resolved.number) })
        if config_err then error(config_err, 0) end
        local _, url_err = async.git(resolved.root, { 'config', 'branch.' .. branch .. '.pullRequestUrl', current.url })
        if url_err then error(url_err, 0) end
        return path
      end, function(created)
        -- Tab-local cwd preserves current editing buffers and the source worktree.
        vim.cmd('tabnew')
        vim.cmd('tcd ' .. vim.fn.fnameescape(created))
        require('git.features.status').open({ work_tree = created })
      end, true)
    end)
  end)
end
function M.modify(opts, action)
  M.run(opts, function(ctx)
    local pr = github.pr(ctx)
    local args = { 'pr', action, tostring(ctx.number), '--repo', github.repo_arg(ctx) }
    if action == 'ready' and pr.isDraft ~= true then args[#args + 1] = '--undo' end
    return github.command(ctx, args)
  end, function() vim.notify('PR updated') end, true)
end
function M.merge(opts)
  M.run(opts, github.pr, function(pr, ctx)
    vim.ui.select({ 'squash', 'merge', 'rebase' }, { prompt = 'Merge PR #' .. pr.number .. ' using:' }, function(method)
      if not method then return end
      M.run(ctx, function(resolved)
        return github.command(resolved, { 'pr', 'merge', tostring(resolved.number), '--repo', github.repo_arg(resolved),
          '--' .. method, '--match-head-commit', pr.headRefOid })
      end, function() vim.notify('PR merged or queued') end, true)
    end)
  end)
end
local function octo_command(opts, command)
  -- Octo's creation/issue commands discover their repository through cwd.
  -- A separate tab keeps that context stable throughout asynchronous prompts.
  if not opts.root then notify('Not in a Git repository'); return end
  vim.cmd('tabnew')
  vim.cmd('tcd ' .. vim.fn.fnameescape(opts.root))
  vim.cmd(command)
end
function M.open(opts)
  opts = vim.deepcopy(opts or M.context())
  local actions = {
    { key = 'p', label = 'Current / selected PR status', run = function() require('git.features.pr').open(opts) end },
    { key = 'l', label = 'List pull requests', run = function() M.list(opts) end },
    { key = 'c', label = 'Create PR (Octo editor)', run = function()
      octo_command(opts, 'Octo pr create')
    end },
    { key = 'C', label = 'Quick PR: title only, defaults from commits', run = function() M.create_quick(opts) end },
    { key = 'e', label = 'Edit / discuss in Octo', run = function() M.octo(opts) end },
    { key = 'r', label = 'Review in Octo', run = function() M.octo(opts, true) end },
    { key = 'w', label = 'Checkout PR in new worktree', run = function() M.worktree(opts) end },
    { key = 'k', label = 'CI checks', run = function()
      require('git.features.github_checks').checks(opts)
    end },
    { key = 'a', label = 'GitHub Actions runs', run = function() require('git.features.github_checks').runs(opts) end },
    { key = 'd', label = 'Toggle draft / ready', run = function() M.modify(opts, 'ready') end },
    { key = 'm', label = 'Merge PR…', run = function() M.merge(opts) end },
    { key = 'i', label = 'Issues (Octo)', run = function() octo_command(opts, 'Octo issue list') end },
    { key = 'n', label = 'Notifications (Octo)', run = function() octo_command(opts, 'Octo notification list') end },
  }
  return require('git.features.transient_menu').show({ kind = 'github', title = 'GitHub',
    context = opts.url or opts.root or '', groups = { { title = 'Pull requests', actions = actions } } })
end
function M.attach(buf)
  vim.keymap.set('n', 'N', function() M.open(M.context(buf)) end,
    { buffer = buf, silent = true, nowait = true, desc = 'GitHub / pull requests' })
end
function M.setup()
  vim.api.nvim_create_user_command('GitHub', function() M.open() end, {})
  vim.api.nvim_create_user_command('GitPrCreate', function() M.create_quick(M.context()) end, {})
  vim.api.nvim_create_user_command('GitPrWorktree', function(args)
    local ctx = M.context()
    if args.args ~= '' then
      if github.url_context(args.args) then ctx.url = args.args
      elseif tonumber(args.args) then ctx.number = tonumber(args.args)
      else notify('Use :GitPrWorktree [PR number or URL]'); return end
    end
    M.worktree(ctx)
  end, { nargs = '?' })
end
return M
