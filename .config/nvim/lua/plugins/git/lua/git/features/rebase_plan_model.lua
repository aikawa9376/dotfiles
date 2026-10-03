-- An immutable source range and a validated, editable linear rebase plan.
local M = {}
local git = require('git.features.commit_model').git
local history = require('git.features.history_rewrite')
local source = debug.getinfo(1, 'S').source:sub(2)
local function run(root, args)
  local out, err = git(root, args)
  if not out then error(err, 0) end
  return vim.trim(out)
end
local function resolve(root, revision)
  return run(root, { 'rev-parse', '--verify', '--end-of-options', revision .. '^{commit}' })
end
local function branch(root)
  return vim.trim(git(root, { 'symbolic-ref', '--quiet', 'HEAD' }) or '')
end

function M.load(root, opts)
  opts = opts or {}
  local tx, err = history.prepare(root, {})
  if not tx then error(err, 0) end
  if require('git.features.rebase_plan_session').pending(root) then
    error('Saved rebase plan exists; use GitRebaseContinue or GitRebaseAbort first', 0)
  end
  local base = opts.base
  if base == '--root' then base = false
  elseif base then base = resolve(root, base)
  elseif opts.commit then
    local selected = resolve(root, opts.commit)
    if not git(root, { 'merge-base', '--is-ancestor', selected, tx.head }) then
      error('Selected commit must be an ancestor of HEAD', 0)
    end
    local parents = run(root, { 'show', '-s', '--format=%P', selected })
    base = parents:match('^(%x+)') or false
  else
    local upstream = git(root, { 'rev-parse', '--verify', '@{upstream}' })
    base = upstream and vim.trim(git(root, { 'merge-base', tx.head, vim.trim(upstream) }) or '') or nil
    if not base or base == '' or base == tx.head then
      local recent = vim.split(run(root, { 'rev-list', '--first-parent', '--max-count=21', tx.head }), '\n')
      base = #recent == 21 and recent[21] or false
    end
  end
  if base and not git(root, { 'merge-base', '--is-ancestor', base, tx.head }) then
    error('Old base must be an ancestor of HEAD', 0)
  end
  local args = { 'log', '--reverse', '--topo-order', '--no-show-signature', '--format=%H%x00%P%x00%B%x00', tx.head }
  if base then args[#args + 1] = '^' .. base end
  args[#args + 1] = '--'
  local entries, by_hash, previous = {}, {}, base
  for hash, parents, message in run(root, args):gmatch('(%x+)%z([^%z]*)%z([^%z]*)%z') do
    if parents ~= (previous or '') then error('Rebase plan requires a linear range; use interactive rebase for merge topology', 0) end
    message = message:gsub('\n+$', '')
    local entry = { hash = hash, message = message, subject = message:match('^[^\n]*') }
    entries[#entries + 1], by_hash[hash], previous = entry, entry, hash
  end
  if #entries == 0 then error('No commits after the old base', 0) end
  return { root = root, head = tx.head, branch = branch(root), base = base,
    onto = opts.onto and resolve(root, opts.onto) or base, entries = entries, by_hash = by_hash }
end

local aliases = { p = 'pick', r = 'reword', s = 'squash', f = 'fixup', d = 'drop', e = 'edit' }
local allowed = { pick = true, reword = true, squash = true, fixup = true, drop = true, edit = true }
function M.entry(model, line)
  if line:find('[%z\r\n]') then return nil, 'A todo row must be a single line' end
  if line:match('^%s*break%s*$') or line:match('^%s*b%s*$') then return { action = 'break', control = true } end
  local command = line:match('^%s*exec%s+(.+)$') or line:match('^%s*x%s+(.+)$')
  if command then
    if not command:find('%S') then return nil, 'Exec needs a shell command' end
    return { action = 'exec', command = command, control = true }
  end
  local action, short, subject = line:match('^%s*(%a+)%s+(%x+)%s+(.*)$')
  if not action then return nil, 'Expected: action hash subject' end
  action = aliases[action] or action
  if not allowed[action] then return nil, 'Unsupported plan action: ' .. action end
  local found = model.by_hash[short]
  if not found and #short == 12 then
    if not model.prefixes then
      model.prefixes = {}
      for hash, value in pairs(model.by_hash) do
        local prefix = hash:sub(1, 12)
        if model.prefixes[prefix] ~= nil then model.prefixes[prefix] = false
        else model.prefixes[prefix] = value end
      end
    end
    found = model.prefixes[short]
    if found == false then return nil, 'Ambiguous commit: ' .. short end
  elseif not found then
    for hash, value in pairs(model.by_hash) do
      if hash:sub(1, #short) == short then
        if found then return nil, 'Ambiguous commit: ' .. short end
        found = value
      end
    end
  end
  if not found then return nil, 'Commit is outside this plan: ' .. short end
  if not subject:find('%S') then return nil, 'Commit subject cannot be empty' end
  return { action = action, hash = found.hash, subject = subject, original = found }
end

function M.parse(model, lines, drafts)
  local rows, seen, predecessor, commits = {}, {}, false, 0
  for number, line in ipairs(lines) do
    if line:find('%S') and not line:match('^%s*#') then
      local row, err = M.entry(model, line)
      if not row then return nil, ('Line %d: %s'):format(number, err) end
      if not row.control then
        commits = commits + 1
        if seen[row.hash] then return nil, 'Duplicate commit: ' .. row.hash:sub(1, 12) end
        seen[row.hash] = true
        if row.action == 'fixup' or row.action == 'squash' then
          if not predecessor then return nil, 'Fixup/squash needs a preceding retained commit' end
          if row.subject ~= row.original.subject or (drafts or {})[row.hash] then
            return nil, 'Use reword to edit a message; fixup/squash combines it with the previous commit'
          end
        end
        local message = (drafts or {})[row.hash] or row.original.message
        row.message = row.subject .. (message:match('(\n.*)$') or '')
        if row.action == 'pick' and row.message ~= row.original.message then row.action = 'reword' end
        if row.action == 'edit' and row.message ~= row.original.message then
          return nil, 'Use reword for draft messages; edit pauses for manual amendment'
        end
        if row.action ~= 'drop' then predecessor = true end
      end
      rows[#rows + 1] = row
    end
  end
  if commits == 0 then return nil, 'Plan is empty; mark commits as drop explicitly to remove the entire range' end
  -- Deleted rows mean drop, but never accept arbitrary new commits or duplicates.
  for _, entry in ipairs(model.entries) do
    if not seen[entry.hash] then rows[#rows + 1] = { hash = entry.hash, action = 'drop', subject = entry.subject } end
  end
  if not predecessor and not model.onto then return nil, 'Cannot drop the entire history' end
  return rows
end

-- Git still generates its todo first; verify its complete source set before replacing it.
function M.todo(lines, rows, expected)
  local actual = {}
  for _, line in ipairs(lines) do
    local hash = line:match('^pick (%x+) ')
    if hash then actual[hash] = true
    elseif line:find('%S') and not line:match('^#') then return nil, 'Unexpected non-linear Git todo' end
  end
  for _, hash in ipairs(expected) do
    if not actual[hash] then return nil, 'Git todo changed or skipped commit ' .. hash end
    actual[hash] = nil
  end
  if next(actual) then return nil, 'Git todo contains an unexpected commit' end
  local result = {}
  for _, row in ipairs(rows) do
    result[#result + 1] = row.control and (row.action .. (row.command and (' ' .. row.command) or ''))
      or (row.action .. ' ' .. row.hash .. ' ' .. row.subject)
  end
  return result
end

function M.execute(model, rows)
  local root = model.root
  if run(root, { 'rev-parse', 'HEAD' }) ~= model.head or branch(root) ~= model.branch then
    return nil, 'HEAD or branch changed; reopen the rebase plan'
  end
  local tx, err = history.prepare(root, {}, model.head)
  if not tx then return nil, err end
  local unchanged = model.base == model.onto and #rows == #model.entries
  for i, row in ipairs(rows) do
    unchanged = unchanged and row.action == 'pick' and row.hash == model.entries[i].hash
  end
  if unchanged then return model.head, nil, false end
  if require('git.features.rebase_plan_session').pending(root) then return nil, 'Continue or abort the saved rebase plan first' end
  local resumable = false
  for _, row in ipairs(rows) do if row.control or row.action == 'edit' then resumable = true end end
  local opts = resumable and require('git.features.rebase_plan_session').options(model) or nil
  local result = { history.execute(tx, function()
    if vim.trim(tx:run({ 'rev-parse', 'HEAD' })) ~= model.head or branch(root) ~= model.branch then
      error('HEAD or branch changed; reopen the rebase plan', 0)
    end
    local hashes, messages = {}, {}
    for _, entry in ipairs(model.entries) do hashes[#hashes + 1] = entry.hash end
    for _, row in ipairs(rows) do if row.action == 'reword' then messages[row.hash] = row.message end end
    local path = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source))) .. '/?.lua;'
    local sequence = tx:temp({
      'package.path = ' .. string.format('%q', path) .. ' .. package.path',
      'local rows = ' .. vim.inspect(rows),
      'local expected = ' .. vim.inspect(hashes),
      'local file = vim.v.argv[#vim.v.argv]',
      'local lines, err = require("git.features.rebase_plan_model").todo(vim.fn.readfile(file), rows, expected)',
      'if not lines then io.stderr:write(err .. "\\n"); vim.cmd("cquit"); return end',
      opts and ('vim.fn.writefile({ ' .. string.format('%q', opts.owner) .. ' }, vim.fs.dirname(file) .. "/git-ui-plan-owner")') or '-- No resumable owner',
      'vim.fn.writefile(lines, file)',
    })
    -- The most recently executed todo row identifies the original reword target.
    -- Message text is data, passed through a Lua table and the editor file, never a shell command.
    local editor = tx:temp({
      'local messages = ' .. vim.inspect(messages),
      'local hash',
      'for _, line in ipairs(vim.fn.readfile(' .. string.format('%q', tx.dir .. '/rebase-merge/done') .. ')) do',
      '  hash = line:match("^reword (%x+) ") or line:match("^squash (%x+) ") or line:match("^fixup (%x+) ")',
      'end',
      'if messages[hash] then vim.fn.writefile(vim.split(messages[hash], "\\n", {plain=true}), vim.v.argv[#vim.v.argv]) end',
    })
    local function command(file)
      return vim.fn.shellescape(vim.v.progpath) .. ' --headless --clean -u NONE -l ' .. vim.fn.shellescape(file)
    end
    if opts then opts.editor(command(editor)) end
    local args = { '-c', 'core.abbrev=no', '-c', 'rebase.abbreviateCommands=false',
      '-c', 'rebase.autoSquash=false', '-c', 'rebase.updateRefs=false', '-c', 'rebase.missingCommitsCheck=ignore',
      'rebase', '--interactive', '--force-rebase', '--no-fork-point', '--reapply-cherry-picks', '--keep-empty', '--empty=keep', '--no-reschedule-failed-exec' }
    if model.onto then vim.list_extend(args, { '--onto', model.onto }) end
    args[#args + 1] = model.base or '--root'
    tx.mutated = true
    tx:run(args, { env = { GIT_SEQUENCE_EDITOR = command(sequence), GIT_EDITOR = command(editor) } })
    return vim.trim(tx:run({ 'rev-parse', 'HEAD' }))
  end, opts) }
  if opts then opts.cleanup(result[4]) end
  return unpack(result, 1, 4)
end

return M
