local M = {}
local github = require('git.features.github')
local actions = require('git.features.github_actions')
local function pages(ctx, endpoint)
  local result = {}
  for _, page in ipairs(github.json(ctx, { 'api', '--hostname', ctx.host, '--paginate', '--slurp', endpoint .. '?per_page=100' })) do
    vim.list_extend(result, page)
  end
  return result
end
function M.candidates(ctx, field)
  assert(field == 'labels' or field == 'assignees', 'Invalid metadata candidates')
  local result = {}
  for _, item in ipairs(pages(ctx, 'repos/' .. ctx.repo .. '/' .. field)) do
    result[#result + 1] = item[field == 'labels' and 'name' or 'login']
  end
  table.sort(result)
  return result
end
function M.load(ctx, field)
  assert(ctx.resource_kind ~= 'issue' or field ~= 'reviewers', 'Issues have no review requests')
  assert(vim.tbl_contains({ 'labels', 'assignees', 'reviewers' }, field), 'Invalid PR metadata field')
  local base, current, candidates = 'repos/' .. ctx.repo, {}, {}
  if field == 'reviewers' then
    local requests = github.api(ctx, base .. '/pulls/' .. ctx.number .. '/requested_reviewers')
    for _, user in ipairs(requests.users or {}) do current[user.login] = true end
    for _, team in ipairs(requests.teams or {}) do current['team:' .. team.slug] = true end
    local pr = github.pr(ctx)
    for _, user in ipairs(pages(ctx, base .. '/collaborators')) do
      if not pr.author or user.login ~= pr.author.login then candidates[#candidates + 1] = user.login end
    end
    local owner = ctx.repo:match('^([^/]+)/')
    local ok, teams = pcall(pages, ctx, 'orgs/' .. owner .. '/teams')
    if ok then for _, team in ipairs(teams) do candidates[#candidates + 1] = 'team:' .. team.slug end end
  else
    local pr = ctx.resource_kind == 'issue' and github.issue(ctx) or github.pr(ctx)
    for _, item in ipairs(github.scalar(pr[field]) or {}) do current[item[field == 'labels' and 'name' or 'login']] = true end
    candidates = M.candidates(ctx, field)
  end
  for name in pairs(current) do if not vim.tbl_contains(candidates, name) then candidates[#candidates + 1] = name end end
  table.sort(candidates)
  return { current = current, candidates = candidates }
end
function M.change(ctx, field, name, present)
  -- Change only the selected membership, preserving others' concurrent edits.
  local fresh = M.load(ctx, field)
  assert((fresh.current[name] == true) == present, 'Metadata changed; reopen the selector')
  if ctx.resource_kind == 'issue' then require('git.features.issue_model').permit(ctx, field) end
  local base = 'repos/' .. ctx.repo
  if field == 'labels' then
    local path = base .. '/issues/' .. ctx.number .. '/labels'
    if present then return github.api(ctx, path .. '/' .. vim.uri_encode(name, 'rfc2396'), nil, 'DELETE') end
    return github.api(ctx, path, { labels = { name } })
  elseif field == 'assignees' then
    return github.api(ctx, base .. '/issues/' .. ctx.number .. '/assignees', { assignees = { name } }, present and 'DELETE' or 'POST')
  end
  local team = name:match('^team:(.+)$')
  local payload = team and { team_reviewers = { team } } or { reviewers = { name } }
  return github.api(ctx, base .. '/pulls/' .. ctx.number .. '/requested_reviewers', payload, present and 'DELETE' or 'POST')
end
function M.choose(ctx, field)
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  actions.run(ctx, function(target) return M.load(target, field) end, function(snapshot, resolved)
    if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= buf or vim.api.nvim_get_current_win() ~= win then return end
    local choices = { { done = true, name = 'Done' } }
    for _, name in ipairs(snapshot.candidates) do choices[#choices + 1] = { name = name, present = snapshot.current[name] == true } end
    vim.ui.select(choices, { prompt = (ctx.resource_kind == 'issue' and 'Issue ' or 'PR ') .. field .. ' · select to add/remove', format_item = function(item)
      return item.done and item.name or ((item.present and '✓ ' or '  ') .. item.name)
    end }, function(item)
      if not item or item.done then return end
      if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= buf then return end
      actions.run(resolved, function(target) return M.change(target, field, item.name, item.present) end, function()
        vim.notify((ctx.resource_kind == 'issue' and 'Issue ' or 'PR ') .. field .. ' updated'); M.choose(resolved, field)
      end, true)
    end)
  end)
end
function M.menu(ctx)
  local issue = ctx.resource_kind == 'issue'
  local entries = {
    { key = 'l', label = 'Labels…', run = function() M.choose(ctx, 'labels') end },
    { key = 'a', label = 'Assignees…', run = function() M.choose(ctx, 'assignees') end },
  }
  if not issue then entries[#entries + 1] = { key = 'r', label = 'Review requests…', run = function() M.choose(ctx, 'reviewers') end } end
  require('git.features.transient_menu').show({ kind = issue and 'issue-metadata' or 'pr-metadata', title = issue and 'Issue metadata' or 'PR metadata',
    groups = { { title = 'Choose / toggle', actions = entries } } })
end
return M
