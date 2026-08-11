local M = {}

local function run(work_tree, args)
  local command = { 'git' }
  vim.list_extend(command, args)
  return vim.system(command, { cwd = work_tree, text = true }):wait()
end

local function output(work_tree, args)
  local result = run(work_tree, args)
  if result.code ~= 0 then return nil end
  local value = vim.trim(result.stdout or '')
  return value ~= '' and value or nil
end

local function configured_upstream(work_tree, branch)
  if not branch or branch == '' or branch == '(detached)' then return nil end
  local remote = output(work_tree, { 'config', '--get', 'branch.' .. branch .. '.remote' })
  local merge = output(work_tree, { 'config', '--get', 'branch.' .. branch .. '.merge' })
  if not remote or not merge then return nil end
  local name = merge:gsub('^refs/heads/', '')
  local display = remote == '.' and name or (remote .. '/' .. name)
  local ref = remote == '.' and ('refs/heads/' .. name) or ('refs/remotes/' .. remote .. '/' .. name)
  local exists = run(work_tree, { 'show-ref', '--verify', '--quiet', ref }).code == 0
  return { display = display, remote = remote, branch = name, gone = not exists }
end

local function inspect_repository(work_tree)
  local status = run(work_tree, { 'status', '--porcelain=v2', '--branch', '--untracked-files=normal' })
  if status.code ~= 0 then return {} end
  local repository = { dirty = false }
  for line in (status.stdout or ''):gmatch('[^\r\n]+') do
    local head = line:match('^# branch%.head (.+)$')
    if head then repository.branch = head
    elseif not line:match('^#') then repository.dirty = true end
  end
  repository.upstream = configured_upstream(work_tree, repository.branch)
  if repository.branch == '(detached)' then repository.detached = true end
  return repository
end

local function unpushed_count(work_tree, upstream)
  local args
  if upstream and not upstream.gone then
    args = { 'rev-list', '--count', upstream.display .. '..HEAD' }
  elseif output(work_tree, { 'remote' }) then
    args = { 'rev-list', '--count', 'HEAD', '--not', '--remotes' }
  else
    return 0
  end
  return tonumber(output(work_tree, args)) or 0
end

function M.inspect(work_tree)
  local state = inspect_repository(work_tree)
  state.work_tree = work_tree
  state.superproject = output(work_tree, { 'rev-parse', '--show-superproject-working-tree' })
  state.submodules = {}

  local result = run(work_tree, { 'submodule', 'status', '--recursive' })
  if result.code == 0 then
    for line in (result.stdout or ''):gmatch('[^\r\n]+') do
      local prefix, hash, rest = line:match('^(.)(%x+) (.+)$')
      local path = rest and (rest:match('^(.-)%s+%(') or rest) or nil
      if prefix and hash and path then
        local item = { path = path, hash = hash:sub(1, 7), state = prefix }
        if prefix ~= '-' then
          local child = vim.fs.joinpath(work_tree, path)
          local details = inspect_repository(child)
          item.branch = details.branch
          item.detached = details.detached
          item.dirty = details.dirty
          item.upstream = details.upstream
          item.unpushed = unpushed_count(child, details.upstream)
        end
        table.insert(state.submodules, item)
      end
    end
  end
  return state
end

function M.status_lines(state)
  if not state then return {} end
  local has_repository_issue = state.detached or (state.upstream and state.upstream.gone) or state.superproject
  if not has_repository_issue and #state.submodules == 0 then return {} end

  local lines = { '', 'Repository health' }
  if state.detached then table.insert(lines, 'HEAD: detached') end
  if state.upstream and state.upstream.gone then
    table.insert(lines, 'Upstream: ' .. state.upstream.display .. ' [gone]')
  end
  if state.superproject then table.insert(lines, 'Superproject: ' .. state.superproject) end
  if #state.submodules > 0 then
    table.insert(lines, ('Submodules (%d)'):format(#state.submodules))
    for _, item in ipairs(state.submodules) do
      local flags = {}
      if item.state == '-' then table.insert(flags, 'uninitialized') end
      if item.state == '+' then table.insert(flags, 'recorded SHA differs') end
      if item.state == 'U' then table.insert(flags, 'conflicted') end
      if item.detached then table.insert(flags, 'detached') end
      if item.dirty then table.insert(flags, 'dirty') end
      if item.unpushed and item.unpushed > 0 then table.insert(flags, 'unpushed:' .. item.unpushed) end
      if item.upstream and item.upstream.gone then table.insert(flags, 'upstream gone') end
      local branch = item.branch and item.branch ~= '(detached)' and item.branch or '-'
      local suffix = #flags > 0 and (' [' .. table.concat(flags, ', ') .. ']') or ''
      table.insert(lines, ('Submodule [%s]  %s  %s%s'):format(item.path, item.hash, branch, suffix))
    end
  end
  return lines
end

function M.submodule_path(line)
  return line and line:match('^Submodule %[(.-)%]%s') or nil
end

function M.run(work_tree, args, callback)
  local command = { 'git' }
  vim.list_extend(command, args)
  vim.system(command, { cwd = work_tree, text = true }, function(result)
    vim.schedule(function()
      local message = vim.trim((result.stdout or '') .. (result.stderr or ''))
      callback(result.code == 0, message ~= '' and message or 'Repository health updated')
    end)
  end)
end

return M
