-- Attribute a staged logical change to one commit without mutating the index.
local M = {}
local git = require('git.features.commit_model').git
local async = require('git.features.async')
local function run(root, args, opts)
  local out, err = git(root, args, opts)
  if not out then error(err, 0) end
  return out
end
local function hash(root, ref)
  return vim.trim(run(root, { 'rev-parse', '--verify', '--end-of-options', ref .. '^{commit}' }))
end
local function subject(value)
  local stripped = value:gsub('^fixup! ', ''):gsub('^squash! ', ''):gsub('^amend! ', '')
  while stripped ~= value do value = stripped; stripped = value:gsub('^fixup! ', ''):gsub('^squash! ', ''):gsub('^amend! ', '') end
  return value
end
local function diff(root, cached)
  local args = { 'diff', '--no-renames', '--no-ext-diff', '--no-textconv', '--no-color', '-U0' }
  if cached then args[#args + 1] = '--cached' end
  vim.list_extend(args, { 'HEAD', '--' })
  return run(root, args)
end
local function blame(root, path, start, count)
  local output, err = git(root, { 'blame', '--line-porcelain', '-L' .. start .. ',+' .. count, 'HEAD', '--', path })
  if not output then return nil, err end
  local hashes = {}
  for line in output:gmatch('[^\n]+') do
    local h = line:match('^(%x+) %d+ %d+')
    if h then hashes[h] = true end
  end
  return hashes
end

function M.detect(root)
  local head = hash(root, 'HEAD')
  local cached = true
  local original = diff(root, cached)
  if original == '' then cached = false; original = diff(root, cached) end
  if original == '' then error('No tracked changes to attribute; stage new files first', 0) end
  local args = { 'diff', '--name-only', '-z', '--no-renames' }
  if cached then args[#args + 1] = '--cached' end
  vim.list_extend(args, { 'HEAD', '--' })
  local deleted, added = {}, {}
  for _, path in ipairs(vim.split(run(root, args), '\0', { plain = true, trimempty = true })) do
    local a = { '--literal-pathspecs', 'diff', '--no-renames', '--no-color', '--no-ext-diff', '--no-textconv', '-U0' }
    if cached then a[#a + 1] = '--cached' end
    vim.list_extend(a, { 'HEAD', '--', path })
    for line in run(root, a):gmatch('[^\n]+') do
      local start, count = line:match('^@@ %-(%d+),(%d+) ')
      if not start then start = line:match('^@@ %-(%d+) '); count = start and '1' end
      if start then
        local hunk = { path = path, start = tonumber(start), count = tonumber(count) }
        local list = hunk.count > 0 and deleted or added
        list[#list + 1] = hunk
      end
    end
  end
  local candidates = {}
  local function include(hashes)
    for h in pairs(hashes or {}) do candidates[h] = true end
  end
  if #deleted > 0 then
    for _, h in ipairs(deleted) do
      local hashes, err = blame(root, h.path, h.start, h.count)
      if not hashes then error(err, 0) end
      include(hashes)
    end
  else
    for _, h in ipairs(added) do
      local before = h.start > 0 and blame(root, h.path, h.start, 1) or nil
      local after = blame(root, h.path, h.start + 1, 1)
      local hashes = {}
      for k in pairs(before or {}) do hashes[#hashes + 1] = k end
      for k in pairs(after or {}) do if not vim.tbl_contains(hashes, k) then hashes[#hashes + 1] = k end end
      if #hashes == 0 then error('Cannot attribute an entirely new file or addition without existing lines', 0) end
      if #hashes == 2 then
        if git(root, { 'merge-base', '--is-ancestor', hashes[1], hashes[2] }) then hashes = { hashes[2] }
        elseif git(root, { 'merge-base', '--is-ancestor', hashes[2], hashes[1] }) then hashes = { hashes[1] }
        else error('Insertion neighbours belong to unrelated histories; select the target manually', 0) end
      end
      for _, hsh in ipairs(hashes) do candidates[hsh] = true end
    end
  end
  local main = {}
  for _, ref in ipairs(vim.g.git_main_branches or { 'main', 'master' }) do
    local h = git(root, { 'rev-parse', '--verify', '--end-of-options', 'refs/heads/' .. ref })
    if h then main[#main + 1] = vim.trim(h) end
  end
  local found = {}
  for h in pairs(candidates) do
    local merged = false
    for _, base in ipairs(main) do
      if git(root, { 'merge-base', '--is-ancestor', h, base }) then merged = true; break end
    end
    if not merged and git(root, { 'merge-base', '--is-ancestor', h, head }) then
      found[#found + 1] = { hash = h, subject = vim.trim(run(root, { 'show', '-s', '--format=%s', h })) }
    end
  end
  -- Fold helper commits only if their real base is present among candidates.
  local bases = {}
  for _, c in ipairs(found) do if c.subject == subject(c.subject) then bases[c.subject] = true end end
  found = vim.tbl_filter(function(c) return c.subject == subject(c.subject) or not bases[subject(c.subject)] end, found)
  table.sort(found, function(a, b) return a.hash < b.hash end)
  if #found == 0 then error('No fixup target on this branch; changes may belong to a main branch', 0) end
  if #found > 1 then
    local names = {}
    for _, c in ipairs(found) do names[#names + 1] = c.hash:sub(1, 10) .. ' ' .. c.subject end
    error('Changes belong to multiple commits; stage one logical change first:\n' .. table.concat(names, '\n'), 0)
  end
  if hash(root, 'HEAD') ~= head or diff(root, cached) ~= original then error('Changes changed while detecting; try again', 0) end
  return { commit = found[1], head = head, cached = cached, diff = original,
    inferred_additions = #deleted > 0 and #added > 0 }
end

function M.open(ctx)
  local root = ctx.work_tree
  if not root then return end
  local function current()
    return not ctx.bufnr or vim.api.nvim_buf_is_loaded(ctx.bufnr)
  end
  local task, err = async.run(root, function() return M.detect(root) end, function(ok, result)
    if not current() then return end
    if not ok then vim.notify(result, vim.log.levels.WARN); return end
    local c = result.commit
    local choices = { 'Inspect target', 'Create fixup from staged changes', 'Amend target from staged changes' }
    local prompt = c.hash:sub(1, 10) .. ' ' .. c.subject
    if result.inferred_additions then prompt = prompt .. ' (addition-only hunks assumed related)' end
    if not result.cached then prompt = prompt .. ' — unstaged: stage changes before committing' end
    vim.ui.select(choices, { prompt = prompt }, function(choice)
      if not choice or not current() then return end
      if choice == choices[1] then
        require('git.features.commit').open({ work_tree = root, revision = c.hash, split = true }); return
      end
      if not result.cached then vim.notify('Stage the intended changes and run detection again', vim.log.levels.WARN); return end
      local t, failure = async.run(root, function()
        if hash(root, 'HEAD') ~= result.head or diff(root, true) ~= result.diff then error('HEAD or staged changes changed; run detection again', 0) end
        if choice == choices[2] then
          run(root, { 'commit', '--fixup=' .. c.hash })
          require('git.utils').fire_fugitive_changed({ work_tree = root })
          return hash(root, 'HEAD')
        end
        local target, warning = require('git.features.history_edits').mix_index(root, c.hash)
        if not target then error(warning, 0) end
        return target, warning
      end, function(success, value, warning)
        vim.notify(success and (warning or ('Updated ' .. value:sub(1, 10))) or value,
          success and (warning and vim.log.levels.WARN or vim.log.levels.INFO) or vim.log.levels.ERROR)
      end, { mutation = true })
      if not t then vim.notify(failure, vim.log.levels.WARN) end
    end)
  end)
  if not task then vim.notify(err, vim.log.levels.WARN) end
  return task
end
return M
