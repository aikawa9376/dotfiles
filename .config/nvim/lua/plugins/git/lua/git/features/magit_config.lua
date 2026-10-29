-- Repository configuration is applied immediately, never saved as transient arguments.
local M = {}
local utils = require('git.utils')
local availability = require('git.features.magit_availability')

local function run(ctx, args)
  if not ctx.work_tree then return { code = 1, stderr = 'No repository selected' } end
  local argv = { 'git', '-C', ctx.work_tree }
  vim.list_extend(argv, args)
  return vim.system(argv, { text = true }):wait()
end

local function read(ctx, args)
  local result = run(ctx, args)
  return result.code == 0 and vim.trim(result.stdout or '') or nil
end

local function values(ctx, key)
  local result = run(ctx, { 'config', '--local', '--null', '--get-all', key })
  return result.code == 0 and vim.split(result.stdout, '\0', { trimempty = true }) or {}
end

local function mutate(ctx, args, ui, valid)
  if not availability.valid(ctx, true) then return end
  if valid and not valid() then return end
  if require('git.features.async').busy(ctx.work_tree) then
    vim.notify('A Git history operation is already running', vim.log.levels.WARN)
    return
  end
  local result = run(ctx, args)
  if result.code ~= 0 then
    vim.notify(vim.trim(result.stderr or '') ~= '' and vim.trim(result.stderr)
      or 'Could not update Git configuration', vim.log.levels.ERROR)
    return
  end
  utils.fire_git_changed({ work_tree = ctx.work_tree, bufnr = ctx.bufnr })
  ui.render()
end

local function local_branch(ctx, branch)
  if branch and (read(ctx, { 'show-ref', '--verify', '--quiet', 'refs/heads/' .. branch })
    or read(ctx, { 'symbolic-ref', '--quiet', '--short', 'HEAD' }) == branch) then return true end
  vim.notify('Select an existing local branch', vim.log.levels.WARN)
  return false
end

function M.branch(ctx)
  if ctx.branch then
    if ctx.branch_kind == 'local_' then return ctx.branch end
    return nil
  end
  return read(ctx, { 'symbolic-ref', '--quiet', '--short', 'HEAD' })
end

local function field(ctx, key, variable, choices, valid, available)
  return { key = key, keep_open = true, mutation = true,
    requires = available and { available } or nil, label = function()
    local current = values(ctx, variable)
    return variable .. ': ' .. (#current > 0 and table.concat(current, ', ') or 'unset')
  end, run = function(ui)
    local current = values(ctx, variable)[1]
    local function set(value)
      if value == nil then return end
      value = vim.trim(value)
      if value:find('[\r\n]') then
        vim.notify('Configuration values must be a single line', vim.log.levels.WARN); return
      end
      if value == '' and not current then return end
      mutate(ctx, value == '' and { 'config', '--local', '--unset-all', variable }
        or { 'config', '--local', '--replace-all', variable, value }, ui, valid)
    end
    if choices then
      local candidates = type(choices) == 'function' and choices() or vim.deepcopy(choices)
      table.insert(candidates, 1, '(unset)')
      availability.select(ctx, candidates, { prompt = variable .. ': ' }, function(value)
        set(value == '(unset)' and '' or value)
      end)
    else
      availability.input(ctx, { prompt = variable .. ' (blank clears): ', default = current or '' }, set)
    end
  end }
end

local function remotes(ctx)
  return vim.split(read(ctx, { 'remote' }) or '', '\n', { trimempty = true })
end

function M.branch_groups(ctx, branch)
  local groups = {}
  if branch then
    local prefix = 'branch.' .. branch .. '.'
    local function valid() return local_branch(ctx, branch) end
    local function available(s)
      return s:resolve('refs/heads/' .. branch) ~= nil or s:branch() == branch,
        'Selected local branch no longer exists'
    end
    local function upstream(unset, ui)
      if not valid() then return end
      if unset then
        mutate(ctx, { 'branch', '--unset-upstream', branch }, ui, valid)
      else
        _G.git_config_upstream_completion = function(lead)
          local refs = read(ctx, { 'for-each-ref', '--format=%(refname:lstrip=2)',
            'refs/heads/', 'refs/remotes/' }) or ''
          return vim.tbl_filter(function(ref)
            return ref ~= branch and not ref:match('/HEAD$') and ref:sub(1, #lead) == lead
          end, vim.split(refs, '\n', { trimempty = true }))
        end
        availability.input(ctx, { prompt = 'Upstream for ' .. branch .. ': ',
          completion = 'customlist,v:lua.git_config_upstream_completion',
          default = read(ctx, { 'rev-parse', '--abbrev-ref', branch .. '@{upstream}' }) or '' },
          function(ref)
            if ref and vim.trim(ref) ~= '' then
              mutate(ctx, { 'branch', '--set-upstream-to=' .. vim.trim(ref), branch }, ui, valid)
            end
          end)
      end
    end
    groups[#groups + 1] = { title = 'Configure ' .. branch, actions = {
      { key = 'u', keep_open = true, mutation = true, requires = { available }, label = function()
        local merge = values(ctx, prefix .. 'merge')[1]
        local remote = values(ctx, prefix .. 'remote')[1]
        return merge and ('Unset upstream: ' .. (remote or '?') .. '/' .. merge:gsub('^refs/heads/', ''))
          or 'Set upstream: unset'
      end, run = function(ui) upstream(values(ctx, prefix .. 'merge')[1] ~= nil, ui) end },
      { key = 'U', keep_open = true, mutation = true, requires = { available }, label = 'Set / replace upstream',
        run = function(ui) upstream(false, ui) end },
      field(ctx, 'd', prefix .. 'description', nil, valid, available),
      field(ctx, 'r', prefix .. 'rebase', { 'true', 'merges', 'interactive', 'false' }, valid, available),
      field(ctx, 'p', prefix .. 'pushRemote', function() return remotes(ctx) end, valid, available),
    } }
  end
  groups[#groups + 1] = { title = 'Configure repository defaults', actions = {
    field(ctx, 'R', 'pull.rebase', { 'true', 'merges', 'interactive', 'false' }),
    field(ctx, 'P', 'remote.pushDefault', function() return remotes(ctx) end),
    field(ctx, 'a m', 'branch.autoSetupMerge', { 'true', 'false', 'always', 'inherit', 'simple' }),
    field(ctx, 'a r', 'branch.autoSetupRebase', { 'never', 'local', 'remote', 'always' }),
  } }
  return groups
end

function M.open_branch(ctx, ui, show)
  local branches = vim.split(read(ctx, { 'for-each-ref', '--format=%(refname:lstrip=2)',
    'refs/heads/' }) or '', '\n', { trimempty = true })
  local current = read(ctx, { 'symbolic-ref', '--quiet', '--short', 'HEAD' })
  if current and not vim.tbl_contains(branches, current) then branches[#branches + 1] = current end
  availability.select(ctx, branches, { prompt = 'Configure local branch: ' }, function(branch)
    if not branch or not local_branch(ctx, branch) then return end
    show({ kind = 'branch-config', title = 'Branch configuration', context = 'Ref: ' .. branch,
      groups = M.branch_groups(ctx, branch) }, ui)
  end)
end

-- Multi-valued remote fields edit one entry at a time and preserve its siblings.
local function remote_field(ctx, key, variable, valid, available)
  return { key = key, keep_open = true, mutation = true, requires = { available }, label = function()
    local current = values(ctx, variable)
    return variable .. ': ' .. (#current > 0 and table.concat(current, ', ') or 'unset')
  end, run = function(ui)
    local entries = values(ctx, variable)
    local items = vim.tbl_map(function(value) return { value = value } end, entries)
    items[#items + 1] = { add = true }
    availability.select(ctx, items, { prompt = variable .. ': ', format_item = function(item)
      return item.add and 'Add value' or item.value
    end }, function(item)
      if not item then return end
      availability.input(ctx, { prompt = variable .. ' (blank removes entry): ', default = item.value or '' },
        function(value)
          if value == nil then return end
          value = vim.trim(value)
          if value:find('[\r\n]') then
            vim.notify('Configuration values must be a single line', vim.log.levels.WARN); return
          end
          if item.add and value == '' then return end
          local args
          if item.add then args = { 'config', '--local', '--add', variable, value }
          elseif value == '' then
            args = { 'config', '--local', '--fixed-value', '--unset-all', variable, item.value }
          else args = { 'config', '--local', '--fixed-value', '--replace-all', variable, value, item.value } end
          mutate(ctx, args, ui, valid)
        end)
    end)
  end }
end

function M.remote_groups(ctx, remote)
  local function available(s) return s:remote(remote), 'Selected remote no longer exists' end
  local function valid()
    if vim.tbl_contains(remotes(ctx), remote) then return true end
    vim.notify('Selected remote no longer exists', vim.log.levels.WARN); return false
  end
  local prefix = 'remote.' .. remote .. '.'
  return { { title = 'Configure ' .. remote, actions = {
    remote_field(ctx, 'u', prefix .. 'url', valid, available),
    remote_field(ctx, 'U', prefix .. 'fetch', valid, available),
    remote_field(ctx, 's', prefix .. 'pushurl', valid, available),
    remote_field(ctx, 'S', prefix .. 'push', valid, available),
    field(ctx, 'O', prefix .. 'tagOpt', { '--no-tags', '--tags' }, valid, available),
  } } }
end

function M.remote(ctx)
  local branch = M.branch(ctx)
  local configured = branch and read(ctx, { 'config', '--get', 'branch.' .. branch .. '.remote' })
  local names = remotes(ctx)
  if vim.tbl_contains(names, configured) then return configured end
  return vim.tbl_contains(names, 'origin') and 'origin' or names[1]
end

function M.open_remote(ctx, ui, show)
  availability.select(ctx, remotes(ctx), { prompt = 'Configure remote: ' }, function(remote)
    if not remote then return end
    show({ kind = 'remote-config', title = 'Remote configuration', context = 'Remote: ' .. remote,
      groups = M.remote_groups(ctx, remote) }, ui)
  end)
end

return M
