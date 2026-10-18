-- Published issue/inline comment operations share identity and stale-body guards.
local M = {}
local github = require('git.features.github')
local actions = require('git.features.github_actions')
function M.endpoint(ctx, item)
  assert(type(item.id) == 'number' or tostring(item.id):match('^%d+$'), 'Invalid comment ID')
  local kind = item.kind or 'inline'
  assert(ctx.resource_kind ~= 'issue' or kind == 'comment', 'Issues only have ordinary comments')
  if kind == 'review' then return ('repos/%s/pulls/%d/reviews/%s'):format(ctx.repo, ctx.number, item.id) end
  assert(kind == 'comment' or kind == 'inline', 'Select an issue or inline comment')
  return ('repos/%s/%s/comments/%s'):format(ctx.repo, kind == 'comment' and 'issues' or 'pulls', item.id)
end
function M.read(ctx, item)
  if ctx.resource_kind == 'issue' then github.issue(ctx) end
  local fresh = github.api(ctx, M.endpoint(ctx, item))
  assert(tostring(fresh.id) == tostring(item.id), 'Comment identity changed; reopen it')
  local parent = github.scalar(fresh.issue_url) or github.scalar(fresh.pull_request_url)
  if parent then
    local repo, number = parent:match('/repos/([^/]+/[^/]+)/[^/]+/(%d+)$')
    assert(repo and repo:lower() == ctx.repo:lower() and tonumber(number) == ctx.number, 'Comment belongs to another resource')
  end
  if ctx.resource_kind == 'issue' then assert(parent, 'Comment parent is unavailable') end
  return fresh
end
local function unchanged(ctx, item, own)
  local fresh = M.read(ctx, item)
  assert(fresh.body == item.body and (item.kind == 'review' or not github.scalar(item.updated_at) or fresh.updated_at == item.updated_at),
    'Comment changed on GitHub; reopen it. Your draft is preserved.')
  if own then
    local viewer = github.api(ctx, 'user').login
    assert(fresh.user and fresh.user.login == viewer, 'Only your own published comments can be edited or deleted')
  end
  return fresh
end
function M.edit(ctx, item, body)
  unchanged(ctx, item, true)
  return github.api(ctx, M.endpoint(ctx, item), { body = body }, item.kind == 'review' and 'PUT' or 'PATCH')
end
function M.remove(ctx, item)
  assert(item.kind ~= 'review', 'Submitted reviews cannot be deleted; edit their summary instead')
  unchanged(ctx, item, true)
  return github.command(ctx, { 'api', '--hostname', ctx.host, '--method', 'DELETE', M.endpoint(ctx, item) })
end
function M.toggle_reaction(ctx, item, content)
  assert(item.kind ~= 'review', 'Reactions belong to issue and inline comments')
  local valid = false
  for _, reaction in ipairs(require('git.features.pr_reactions').types) do if content == reaction[1] then valid = true end end
  assert(valid, 'Invalid reaction')
  M.read(ctx, item)
  local endpoint, viewer = M.endpoint(ctx, item) .. '/reactions', github.api(ctx, 'user').login
  local pages = github.json(ctx, { 'api', '--hostname', ctx.host, '--paginate', '--slurp', endpoint .. '?per_page=100' })
  for _, page in ipairs(pages) do for _, reaction in ipairs(page) do
    if reaction.content == content and reaction.user and reaction.user.login == viewer then
      return github.command(ctx, { 'api', '--hostname', ctx.host, '--method', 'DELETE', endpoint .. '/' .. reaction.id })
    end
  end end
  return github.api(ctx, endpoint, { content = content })
end
function M.menu(ctx, original, viewer)
  local item = vim.deepcopy(original)
  if require('git.features.pr_timeline').is_event(item) then vim.notify('Timeline events have no comment actions'); return end
  if item.pending then
    return require('git.features.pr_review').drafts(ctx, { id = item.pull_request_review_id or item.review_id, comments = { item } })
  end
  local source_win, source_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  actions.run(ctx, function(resolved)
    return { comment = M.read(resolved, item), viewer = github.api(resolved, 'user').login }
  end, function(state, resolved)
    if not vim.api.nvim_win_is_valid(source_win) or vim.api.nvim_win_get_buf(source_win) ~= source_buf
      or vim.api.nvim_get_current_win() ~= source_win then return end
    item = vim.tbl_extend('force', item, state.comment)
    viewer = state.viewer
    local own = item.user and item.user.login == viewer
    local function mutate(fn, message)
      actions.run(resolved, fn, function() vim.notify(message) end, true)
    end
    local reactions = {}
    for index, reaction in ipairs(item.kind ~= 'review' and require('git.features.pr_reactions').types or {}) do
      local content = reaction[1]
      reactions[#reactions + 1] = { key = tostring(index), label = reaction[2] .. ' toggle', run = function()
        mutate(function(target) return M.toggle_reaction(target, item, content) end, 'Reaction updated')
      end }
    end
    local operations = {
      { key = 'e', label = item.kind == 'review' and 'Edit review summary' or 'Edit published comment', enabled = own, run = function()
        require('git.features.pr_composer').open({ ctx = resolved, title = 'Edit published comment', body = item.body,
          history = { item }, viewer = viewer, prefix = { 'Comment #' .. item.id }, action = 'save',
          allow_empty = item.kind == 'review', success = 'Comment updated', submit = function(target, body) return M.edit(target, item, body) end,
          delete_prompt = 'Delete published comment #' .. item.id .. '?', delete_success = 'Comment deleted',
          delete = item.kind ~= 'review' and function(target) return M.remove(target, item) end or nil })
      end },
      { key = 'x', label = 'Delete published comment…', enabled = own and item.kind ~= 'review', run = function()
        if vim.fn.confirm('Delete published comment #' .. item.id .. '?', '&Delete\n&Keep', 2) ~= 1 then return end
        mutate(function(target) return M.remove(target, item) end, 'Comment deleted')
      end },
    }
    if #require('git.features.pr_suggestions').parse(item.body) > 0 and (item.kind or 'inline') == 'inline' then
      operations[#operations + 1] = { key = 's', label = 'Apply suggested change…', run = function()
        require('git.features.pr_suggestions').choose(resolved, item)
      end }
    end
    require('git.features.transient_menu').show({ kind = 'pr-comment-actions', title = 'Comment #' .. item.id,
      context = '@' .. (item.user and item.user.login or 'unknown') .. ': ' .. item.body:gsub('[\r\n]', ' '),
      groups = { { title = 'Reactions', actions = reactions }, { title = 'Comment', actions = operations } } },
      { layout = vim.api.nvim_win_get_config(source_win).relative ~= '' and 'float' or nil })
  end)
end
function M.select(ctx, items, viewer)
  items = vim.tbl_filter(function(item) return not require('git.features.pr_timeline').is_event(item) end, items)
  if #items == 0 then vim.notify('No comment at this location'); return end
  if #items == 1 then return M.menu(ctx, items[1], viewer) end
  vim.ui.select(items, { prompt = 'Comment actions', format_item = function(item)
    return ('@%s: %s'):format(item.user and item.user.login or 'unknown', (item.body or ''):gsub('[\r\n]', ' '))
  end }, function(item) if item then M.menu(ctx, item, viewer) end end)
end
return M
