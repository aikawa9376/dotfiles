local M = {}
local github = require('git.features.github')
local actions = require('git.features.github_actions')
function M.panel(ctx, title, entries, fallback)
  local lines = { title, 'gx / Enter opens the selected check or Actions run', '' }
  local links = {}
  for _, entry in ipairs(entries) do
    lines[#lines + 1] = entry.label:gsub('[\r\n]', ' ')
    links[#lines] = entry.url or fallback
  end
  if #entries == 0 then lines[#lines + 1] = 'No results' end
  local buf = require('git.features.workflow').output(ctx.root, title, table.concat(lines, '\n'))
  local function browse() vim.ui.open(links[vim.fn.line('.')] or fallback) end
  vim.keymap.set('n', 'gx', browse, { buffer = buf, silent = true, desc = 'Open selected CI / Actions details' })
  vim.keymap.set('n', '<CR>', browse, { buffer = buf, silent = true })
  return buf
end
function M.checks(opts)
  actions.run(opts, function(ctx) return github.pr(ctx) end, function(pr, ctx)
    M.panel(ctx, 'CI checks · PR #' .. pr.number, github.checks(pr), pr.url .. '/checks')
  end)
end
function M.runs(opts)
  actions.run(opts, function(ctx)
    local args = { 'run', 'list', '--repo', github.repo_arg(ctx), '--limit', '50',
      '--json', 'databaseId,name,displayTitle,status,conclusion,url,headBranch,headSha' }
    local pr
    if ctx.number then pr = github.pr(ctx); vim.list_extend(args, { '--commit', pr.headRefOid })
    else
      local branch = require('git.features.async').git(ctx.root, { 'branch', '--show-current' })
      if branch and vim.trim(branch) ~= '' then vim.list_extend(args, { '--branch', vim.trim(branch) }) end
    end
    return github.json(ctx, args)
  end, function(runs, ctx)
    local entries = {}
    for _, run in ipairs(runs) do
      entries[#entries + 1] = { label = ('#%s %s · %s · %s'):format(run.databaseId, run.name or run.displayTitle or 'Workflow',
        github.scalar(run.conclusion) or run.status, run.headBranch or ''), url = run.url }
    end
    M.panel(ctx, 'GitHub Actions', entries, github.actions_url(ctx))
  end)
end
return M
