local M = {}
local github = require('git.features.github')
local async = require('git.features.async')
local utils = require('git.utils')
local function notify(err) vim.notify(tostring(err), vim.log.levels.ERROR) end
function M.context(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local ctx = { root = utils.get_buf_work_tree(buf) or utils.get_work_tree({}), bufnr = buf }
  local pr
  if vim.bo[buf].filetype == 'gitissue' then
    local model = require('git.features.issue').model(buf)
    if model then ctx = vim.deepcopy(model.ctx) end
  elseif vim.b[buf].git_issue_ctx then
    ctx = vim.deepcopy(vim.b[buf].git_issue_ctx)
  elseif vim.bo[buf].filetype == 'gitpr' then
    local model = require('git.features.pr').model(buf)
    if model then ctx = vim.deepcopy(model.ctx) end
  elseif vim.bo[buf].filetype == 'gitstatus' then
    pr = require('git.features.status').pull_request_at(buf, vim.fn.line('.'))
    if pr then ctx.url = pr.url end
  end
  if not ctx.url and ctx.resource_kind ~= 'issue' then
    local target = require('git.features.magit_actions').context(buf)
    if target then
      ctx.branch, ctx.branch_kind, ctx.commit = target.branch, target.branch_kind, target.commit
      ctx.root = target.target_worktree or ctx.root
      ctx.no_target = vim.tbl_contains({ 'branch', 'log', 'reflog', 'commit' }, target.panel)
        and not (ctx.branch or ctx.commit) or nil
    end
  end
  ctx.bufnr = buf
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
        require('octo.reviews').start_or_resume_review()
      elseif (vim.uv.hrtime() - started) / 1e9 < 15 then vim.defer_fn(ready, 50)
      else notify('Octo did not finish loading the PR') end
    end
    vim.defer_fn(ready, 50)
  end
  M.run(ctx, github.pr, open)
end
function M.create_quick(opts)
  opts = vim.deepcopy(opts or M.context())
  local title_root = opts.root or utils.get_buf_work_tree(opts.bufnr or vim.api.nvim_get_current_buf()) or utils.get_work_tree({})
  if not title_root then notify('Not in a Git repository'); return end
  local function input_title(default_title)
    vim.ui.input({ prompt = 'Default PR title: ', default = default_title }, function(title)
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
  local task, err = async.run(title_root, function()
    local title, log_err = async.git(title_root, { 'log', '-1', '--format=%s' })
    if not title then error(log_err or 'Create a commit before creating a PR', 0) end
    return vim.trim(title)
  end, function(ok, title)
    if ok then input_title(title) else notify(title) end
  end)
  if not task then notify(err) end
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
    vim.ui.select({
      { method = 'merge', label = 'Create a merge commit' },
      { method = 'squash', label = 'Squash and merge' },
      { method = 'rebase', label = 'Rebase and merge' },
    }, { prompt = 'Merge pull request #' .. pr.number, format_item = function(item) return item.label end }, function(item)
      if not item then return end
      M.run(ctx, function(resolved)
        return github.command(resolved, { 'pr', 'merge', tostring(resolved.number), '--repo', github.repo_arg(resolved),
          '--' .. item.method, '--match-head-commit', pr.headRefOid })
      end, function() vim.notify('PR merged or queued') end, true)
    end)
  end)
end
function M.lifecycle(opts, expected)
  M.run(opts, function(ctx)
    local pr = github.pr(ctx)
    assert(pr.state == 'OPEN' or pr.state == 'CLOSED', 'A merged PR cannot be closed or reopened')
    assert(not expected or expected == pr.state, 'PR state changed; reopen the action menu')
    local state = pr.state == 'OPEN' and 'closed' or 'open'
    github.api(ctx, ('repos/%s/pulls/%d'):format(ctx.repo, ctx.number), { state = state }, 'PATCH')
    return state
  end, function(state) vim.notify(state == 'open' and 'PR reopened' or 'PR closed') end, true)
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
  local source = opts.bufnr or vim.api.nvim_get_current_buf()
  opts.root = opts.root or utils.get_buf_work_tree(source) or utils.get_work_tree({ bufnr = source })
  opts.bufnr = source
  if vim.api.nvim_buf_is_valid(source) and vim.bo[source].filetype == 'gitissue' then
    local issue = require('git.features.issue')
    local current = issue.model(source)
    if current and (not opts.root or opts.root == current.ctx.root) and (not opts.url or opts.url == current.ctx.url)
      and (not opts.number or opts.number == current.ctx.number) then
      return require('git.features.transient_menu').show({ kind = 'issue-actions', title = 'Issue actions',
        context = current.ctx.url, groups = issue.action_groups(source) })
    end
  end
  local pr_panel = vim.api.nvim_buf_is_valid(source) and vim.bo[source].filetype == 'gitpr'
  local model = pr_panel and require('git.features.pr').model(source)
  if model and ((opts.root and opts.root ~= model.root) or (opts.url and opts.url ~= model.ctx.url)) then pr_panel = false end
  if pr_panel then
    local pr = require('git.features.pr')
    opts = vim.tbl_extend('force', vim.deepcopy(model and model.ctx or {}), opts, { bufnr = source })
    local groups = pr.action_groups(source)
    groups[#groups + 1] = { title = 'GitHub', actions = {
      { key = 'k', label = 'CI checks', run = function() require('git.features.github_checks').checks(opts) end },
      { key = 'a', label = 'GitHub Actions runs', run = function() require('git.features.github_checks').runs(opts) end },
      { key = 'd', label = 'Toggle draft / ready', enabled = model ~= nil, run = function() M.modify(opts, 'ready') end },
      { key = 'm', label = 'Merge PR…', enabled = model ~= nil, run = function() M.merge(opts) end },
      { key = 'x', label = model and model.pr.state == 'CLOSED' and 'Reopen PR' or 'Close PR',
        enabled = model ~= nil and model.pr.state ~= 'MERGED', run = function() M.lifecycle(opts, model.pr.state) end },
      { key = 'w', label = 'Checkout PR in new worktree', enabled = model ~= nil, run = function() M.worktree(opts) end },
      { key = 'b', label = 'Open PR in browser', enabled = model ~= nil, run = function() vim.ui.open(opts.url) end },
      { key = 'e', label = 'Edit / discuss in Octo', enabled = model ~= nil, run = function() M.octo(opts) end },
      { key = 'O', label = 'Review in Octo', enabled = model ~= nil, run = function() M.octo(opts, true) end },
    } }
    return require('git.features.transient_menu').show({ kind = 'pr-actions', title = 'PR actions',
      context = opts.url or opts.root or '', groups = groups })
  end
  local related = require('git.features.github_related')
  local reload
  local state = { items = {} }
  local function choose(callback, predicate)
    local items = vim.tbl_filter(predicate or function() return true end, state.items)
    local function selected(pr)
      if not pr then return end
      -- Resolve all subsequent actions by this exact URL, even after cursor/cwd changes.
      local target = { root = opts.root, bufnr = source, url = pr.url }
      callback(target, pr)
    end
    if #items == 1 then selected(items[1])
    elseif #items > 1 then
      vim.ui.select(items, { prompt = 'Related pull requests', format_item = related.label }, selected)
    end
  end
  local function pr_action(key, label, callback, predicate)
    return { key = key, label = label, enabled = false, reason = 'PR information is still loading',
      predicate = predicate, run = function() choose(callback, predicate) end }
  end
  local function is_open(pr) return pr.state == 'OPEN' end
  local actions = {
    { key = 'R', label = 'Refresh related PRs', keep_open = true, run = function() reload(true) end },
    pr_action('p', 'Open PR', function(target) require('git.features.pr').open(target) end),
    pr_action('b', 'Open PR in browser', function(target) vim.ui.open(target.url) end),
    { key = 'l', label = 'List pull requests', run = function() M.list(opts) end },
    { key = 'C', label = 'Create default PR (title only)', run = function() M.create_quick(opts) end },
    { key = 'c', label = 'Create PR (Octo editor)', run = function()
      octo_command(opts, 'Octo pr create')
    end },
    pr_action('e', 'Edit / discuss in Octo', function(target) M.octo(target) end),
    pr_action('r', 'Review in Octo', function(target) M.octo(target, true) end, is_open),
    pr_action('w', 'Checkout PR in new worktree', function(target) M.worktree(target) end),
    pr_action('k', 'CI checks', function(target) require('git.features.github_checks').checks(target) end),
    { key = 'a', label = 'GitHub Actions runs', run = function()
      if #state.items > 0 then
        choose(function(target) require('git.features.github_checks').runs(target) end)
      else
        require('git.features.github_checks').runs(vim.tbl_extend('force', opts, { repository_only = true }))
      end
    end },
    pr_action('d', 'Toggle draft / ready', function(target) M.modify(target, 'ready') end, is_open),
    pr_action('m', 'Merge PR…', function(target) M.merge(target) end, is_open),
    pr_action('x', 'Close / reopen PR', function(target, pr) M.lifecycle(target, pr.state) end,
      function(pr) return pr.state ~= 'MERGED' end),
    pr_action('M', 'PR labels / assignees / review requests…', function(target)
      M.run(target, github.pr, function(_, ctx) require('git.features.pr_metadata').menu(ctx) end)
    end),
    { key = 'i', label = 'List Issues (native)', run = function() require('git.features.issue_actions').list(opts) end },
    { key = 'I', label = 'Create Issue (native)', run = function() require('git.features.issue_actions').create(opts) end },
    { key = 'o', label = 'Issues (Octo)', run = function() octo_command(opts, 'Octo issue list') end },
    { key = 'n', label = 'Notifications (Octo)', run = function() octo_command(opts, 'Octo notification list') end },
  }
  local function target_info()
    if opts.commit then return { 'Commit: ' .. opts.commit } end
    if opts.branch then return { 'Ref: ' .. related.clean(opts.branch) } end
    return {}
  end
  local spec = { kind = 'github', title = 'GitHub', context = opts.url or opts.root or '',
    info = target_info(), groups = { { title = 'Pull requests', actions = actions } } }
  spec.info[#spec.info + 1] = 'PR: Loading…'
  local ui = require('git.features.transient_menu').show(spec)
  local function publish(ok, result)
    if not vim.api.nvim_buf_is_valid(ui.bufnr) then return end
    state.items = ok and result.items or {}
    spec.info = target_info()
    if not ok then spec.info[#spec.info + 1] = 'PR: Could not load — ' .. related.clean(result)
    elseif #state.items == 0 then
      spec.info[#spec.info + 1] = { text = 'PR: No related pull requests', hl_group = 'Comment' }
    else
      for index, pr in ipairs(state.items) do
        if index > 5 then
          spec.info[#spec.info + 1] = ('… %d more PRs (p to choose)'):format(#state.items - 5); break
        end
        spec.info[#spec.info + 1] = related.label(pr)
        if pr.statusCheckRollup ~= nil then spec.info[#spec.info + 1] = '  ' .. github.summary(pr) end
      end
    end
    if ok and result.limited then spec.info[#spec.info + 1] = 'PR lookup limited to 100 results' end
    for _, action in ipairs(actions) do
      if action.reason then
        local matches = vim.tbl_filter(action.predicate or function() return true end, state.items)
        action.enabled = #matches > 0
        action.reason = not ok and 'Could not load PR information'
          or #state.items == 0 and 'No matching PR is available'
          or 'This action is unavailable for the related PR state'
        if action.key == 'p' then action.label = #matches > 1 and ('Open PR… (%d)'):format(#matches) or 'Open PR'
        elseif action.key == 'x' and #matches == 1 then
          action.label = matches[1].state == 'CLOSED' and 'Reopen PR' or 'Close PR'
        end
      end
    end
    ui.render()
  end
  local task
  reload = function(force)
    if task then task.cancel() end
    if force then
      related.invalidate(opts.root)
      state.items, spec.info = {}, target_info()
      spec.info[#spec.info + 1] = 'PR: Loading…'
      for _, action in ipairs(actions) do
        if action.reason then action.enabled, action.reason = false, 'PR information is still loading' end
      end
      ui.render()
    end
    task = related.request(opts, publish)
  end
  reload()
  vim.api.nvim_create_autocmd('BufWipeout', { buffer = ui.bufnr, once = true,
    callback = function() if task then task.cancel() end end })
  return ui
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
