local M = {}
local actions = require('git.features.github_actions')
local github = require('git.features.github')
local model = require('git.features.issue_model')
local function repository(opts)
  local ctx = vim.deepcopy(opts or actions.context())
  -- A selected PR/Issue number is not a selector for listing or creation.
  ctx.number, ctx.url, ctx.resource_kind, ctx.repository_only = nil, nil, 'issue', true
  return ctx
end
function M.list(opts, filters)
  local ctx = repository(opts)
  filters = require('git.features.issue_options').normalize(filters)
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  local function valid()
    return vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf and vim.api.nvim_get_current_win() == win
  end
  actions.run(ctx, function(target) return model.list(target, filters) end, function(issues, resolved)
    if not valid() then return end
    local choices = {
      { action = 'state', title = 'Switch to ' .. (filters.state == 'open' and 'closed' or 'open') .. ' Issues' },
      { action = 'labels', title = 'Filter labels: ' .. (filters.labels or 'all') },
      { action = 'assignee', title = 'Filter assignee: ' .. (filters.assignee or 'all') },
      { action = 'create', title = 'Create Issue…' },
    }
    vim.list_extend(choices, issues)
    vim.ui.select(choices, { prompt = ('Issues · %s · %s (%d)'):format(resolved.repo, filters.state .. ' · limit ' .. filters.limit, #issues),
      format_item = function(item) return item.action and item.title or ('#%d %s'):format(item.number, item.title) end }, function(item)
      if not item or not valid() then return end
      if item.action == 'state' then
        filters.state = filters.state == 'open' and 'closed' or 'open'; M.list(resolved, filters)
      elseif item.action == 'labels' or item.action == 'assignee' then
        local field = item.action
        local metadata = require('git.features.pr_metadata')
        -- Repository candidates, with no PR/Issue state lookup.
        actions.run(resolved, function(target) return metadata.candidates(target, field == 'labels' and 'labels' or 'assignees') end,
          function(candidates)
            if not valid() then return end
            local entries = { { value = '', label = 'All' } }
            for _, value in ipairs(candidates) do entries[#entries + 1] = { value = value, label = value } end
            vim.ui.select(entries, { prompt = 'Issue ' .. field, format_item = function(entry) return entry.label end }, function(entry)
              if entry and valid() then filters[field] = entry.value ~= '' and entry.value or nil; M.list(resolved, filters) end
            end)
          end)
      elseif item.action == 'create' then M.create(resolved)
      else require('git.features.issue').open(vim.tbl_extend('force', resolved, { number = item.number, url = item.html_url })) end
    end)
  end)
end
function M.create(opts)
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  actions.run(repository(opts), function(ctx) return ctx end, function(_, ctx)
    if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= buf or vim.api.nvim_get_current_win() ~= win then return end
    require('git.features.pr_composer').open({ ctx = ctx, title = 'Create Issue', action = 'create', body = '\n\n',
      prefix = { 'Repository: ' .. ctx.host .. '/' .. ctx.repo, 'First line: title · blank line · Markdown body' },
      success = 'Issue created', submit = model.create,
      on_success = function(_, resolved) require('git.features.issue').open(resolved) end })
  end)
end
return M
