-- Own the temporary worktree, rebase, and recovery resources for a history edit.
local M = {}
local git = require('git.features.commit_model').git
local utils = require('git.utils')
local module_path = debug.getinfo(1, 'S').source:sub(2)

function M.same_message(root, commit, message)
  local original, err = git(root, { 'show', '--no-patch', '--format=format:%B', commit, '--' })
  if not original then return nil, err end
  -- Git's terminal message separators are not an edit to the message body.
  return original:gsub('\n+$', '') == message:gsub('\n+$', '')
end

function M.index_patch(root)
  return git(root, { 'diff', '--cached', '--binary', '--full-index', '--no-color',
    '--no-ext-diff', '--no-textconv', 'HEAD', '--' })
end

local function active_rebase(dir)
  return vim.uv.fs_stat(dir .. '/rebase-merge') or vim.uv.fs_stat(dir .. '/rebase-apply')
end

function M.prepare(root, commits, expected_head)
  local dir = utils.get_git_dir(root)
  if not dir then return nil, 'Git directory not found' end
  for _, path in ipairs({ 'rebase-merge', 'rebase-apply', 'MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'BISECT_START' }) do
    if vim.uv.fs_stat(dir .. '/' .. path) then return nil, 'Finish the current Git operation first' end
  end
  local head, err = git(root, { 'rev-parse', '--verify', 'HEAD' })
  if not head then return nil, err end
  head = vim.trim(head)
  if expected_head and head ~= expected_head then return nil, 'HEAD changed; reopen the commit before rewriting' end
  local tx = { root = root, dir = dir, head = head, commits = {}, parents = {}, files = {} }
  for _, revision in ipairs(commits) do
    local hash, resolve_err = git(root, { 'rev-parse', '--verify', '--end-of-options', revision .. '^{commit}' })
    if not hash then return nil, resolve_err end
    hash = vim.trim(hash)
    if not git(root, { 'merge-base', '--is-ancestor', hash, head }) then
      return nil, 'The selected commit is not an ancestor of HEAD'
    end
    local parents, parent_err = git(root, { 'show', '-s', '--format=%P', hash })
    if not parents then return nil, parent_err end
    tx.commits[#tx.commits + 1] = hash
    tx.parents[hash] = vim.split(vim.trim(parents), ' ', { trimempty = true })
  end
  function tx:run(args, opts)
    local out, run_err = git(self.root, args, opts)
    if not out then error(run_err, 0) end
    return out
  end
  function tx:temp(lines)
    local path = vim.fn.tempname()
    self.files[#self.files + 1] = path
    vim.fn.writefile(vim.split(table.concat(lines, '\n'), '\n', { plain = true }), path)
    return path
  end
  function tx:rebase(base, plan)
    -- Git invokes a separate Neovim Lua process; no editor RPC/socket is needed.
    -- Transform Git's own todo so labels/reset/merge topology remain intact.
    local editor = self:temp({
      'local plan = ' .. vim.inspect(plan),
      'local todo = vim.v.argv[#vim.v.argv]',
      'package.path = ' .. string.format('%q', vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(module_path))) .. '/?.lua;') .. ' .. package.path',
      'local engine = dofile(' .. string.format('%q', module_path) .. ')',
      'local lines, err = engine.todo(vim.fn.readfile(todo), plan)',
      'if not lines then io.stderr:write(err .. "\\n"); vim.cmd("cquit"); return end',
      'vim.fn.writefile(lines, todo)',
    })
    local command = vim.fn.shellescape(vim.v.progpath) .. ' --headless --clean -u NONE -l ' .. vim.fn.shellescape(editor)
    self.mutated = true
    self:run({ '-c', 'core.abbrev=no', '-c', 'rebase.abbreviateCommands=false',
      '-c', 'rebase.autoSquash=false', '-c', 'rebase.updateRefs=false',
      'rebase', '--interactive', '--rebase-merges', '--empty=keep', base or '--root' },
      { env = { GIT_SEQUENCE_EDITOR = command, GIT_EDITOR = 'true' } })
  end
  return tx
end

-- Pure todo transformations require exact full hashes and validate before writing.
function M.todo(lines, plan)
  local rows = {}
  for row, line in ipairs(lines) do
    local hash = line:match('^pick (%x+) ') or line:match('^merge %-[Cc] (%x+) ')
    if hash then rows[hash] = row end
  end
  local result = vim.deepcopy(lines)
  for _, hash in ipairs(plan.commits) do
    if not rows[hash] then return nil, 'Rebase todo is missing selected commit ' .. hash end
  end
  if plan.action == 'stop' then
    table.insert(result, rows[plan.commits[1]] + 1, 'break')
  elseif plan.action == 'move' then
    local a, b = rows[plan.commits[1]], rows[plan.commits[2]]
    if math.abs(a - b) ~= 1 or not lines[a]:match('^pick ') or not lines[b]:match('^pick ') then
      return nil, 'Only adjacent commits on a linear history can be moved'
    end
    result[a], result[b] = result[b], result[a]
  elseif plan.action == 'drop' or plan.action == 'fixup' then
    for _, hash in ipairs(plan.commits) do
      local row = rows[hash]
      if not lines[row]:match('^pick ') then return nil, 'Cannot ' .. plan.action .. ' a merge commit' end
      if plan.action == 'fixup' and not (lines[row - 1] or ''):match('^pick ' .. plan.parent .. ' ') then
        return nil, 'Fixup requires the selected commit immediately after its parent'
      end
      result[row] = lines[row]:gsub('^pick ', plan.action .. ' ', 1)
    end
  elseif plan.action == 'fold' then
    local target, helper = rows[plan.commits[1]], rows[plan.commits[2]]
    if helper <= target or not lines[target]:match('^pick ') or not lines[helper]:match('^pick ') then
      return nil, 'Cannot fold the index into this commit'
    end
    local command = plan.message and 'fixup -C ' or 'fixup '
    local folded = lines[helper]:gsub('^pick ', command, 1)
    table.remove(result, helper)
    table.insert(result, target + 1, folded)
  else
    return nil, 'Unknown rebase action'
  end
  return result
end

function M.restore_saved(tx, stash, opts, successful)
  local warning
  if stash then
    local restored, restore_err = pcall(function()
      local restore = stash
      if successful and opts and opts.consume_index then
        -- The staged contribution is already committed. Use its saved index as
        -- the merge base so only index-to-worktree edits are restored. Applying
        -- the original stash directly can conflict with that same contribution.
        -- Untracked files stay in the original third parent. No refs are created.
        local index = vim.trim(tx:run({ 'rev-parse', stash .. '^2' }))
        local tree = vim.trim(tx:run({ 'rev-parse', index .. '^{tree}' }))
        local base = vim.trim(tx:run({ '-c', 'commit.gpgsign=false', 'commit-tree', tree }, { stdin = 'nvim saved index base\n' }))
        local args = { '-c', 'commit.gpgsign=false', 'commit-tree', vim.trim(tx:run({ 'rev-parse', stash .. '^{tree}' })), '-p', base, '-p', index }
        local untracked = git(tx.root, { 'rev-parse', '--verify', stash .. '^3' })
        if untracked then vim.list_extend(args, { '-p', vim.trim(untracked) }) end
        restore = vim.trim(tx:run(args, { stdin = 'nvim unstaged changes\n' }))
      end
      tx:run({ 'stash', 'apply', '--index', restore })
    end)
    if not restored then warning = 'Saved changes remain in stash ' .. stash .. ': ' .. tostring(restore_err)
    else
      local top = git(tx.root, { 'rev-parse', 'refs/stash' })
      if top and vim.trim(top) == stash then
        local dropped, drop_err = git(tx.root, { 'stash', 'drop', '--quiet', 'stash@{0}' })
        if not dropped then warning = 'Changes restored; saved stash ' .. stash .. ' was retained: ' .. drop_err end
      end
    end
  end
  return warning
end

function M.execute(tx, change, opts)
  local stash, result
  local ok, failure = pcall(function()
    if tx:run({ 'status', '--porcelain', '--untracked-files=all' }) ~= '' then
      local previous = git(tx.root, { 'rev-parse', '--verify', 'refs/stash' })
      tx:run({ 'stash', 'push', '--include-untracked', '-m', 'nvim Git history rewrite' })
      local saved = git(tx.root, { 'rev-parse', '--verify', 'refs/stash' })
      if saved and saved ~= previous then stash = vim.trim(saved) end
      if tx:run({ 'status', '--porcelain', '--untracked-files=all' }) ~= '' then
        error('Could not save all worktree changes; history was left unchanged', 0)
      end
    end
    if opts and opts.expected_index then
      local index = stash and tx:run({ 'rev-parse', stash .. '^2^{tree}' }) or tx:run({ 'write-tree' })
      if vim.trim(index) ~= opts.expected_index then error('Index changed; reopen Undo/Redo', 0) end
    end
    if opts and opts.before_change then opts.before_change(tx, stash) end
    result = change(tx)
  end)
  if tx.mutated and active_rebase(tx.dir) and opts and opts.suspend then
    local saved, paused = pcall(opts.suspend, tx, stash, ok, failure)
    if saved and paused then
      utils.fire_fugitive_changed({ work_tree = tx.root })
      return paused.head, paused.warning, true, true
    elseif not saved then ok, failure = false, paused end
  end
  for _, path in ipairs(tx.files) do os.remove(path) end
  if not ok and tx.mutated then
    local recovered, recovery_err
    if active_rebase(tx.dir) then
      recovered, recovery_err = git(tx.root, { 'rebase', '--abort' })
      -- Abort returns to the rebase start, which may include our fixup helper.
      -- The transaction began before that helper existed.
      if recovered then recovered, recovery_err = git(tx.root, { 'reset', '--hard', tx.head }) end
    else recovered, recovery_err = git(tx.root, { 'reset', '--hard', tx.head }) end
    if not recovered then
      utils.fire_fugitive_changed({ work_tree = tx.root })
      return nil, tostring(failure) .. '\nHistory rollback failed: ' .. recovery_err
        .. (stash and ('\nSaved changes remain in stash ' .. stash) or '')
    end
  end
  local warning = M.restore_saved(tx, stash, opts, ok)
  if ok and opts and opts.after_restore then
    local finished, finish_warning = pcall(opts.after_restore, warning)
    if finished then warning = finish_warning
    else warning = (warning and warning .. '\n' or '') .. 'History rewritten; final worktree update failed: ' .. tostring(finish_warning) end
  end
  utils.fire_fugitive_changed({ work_tree = tx.root })
  if not ok then return nil, tostring(failure) .. (warning and ('\n' .. warning) or '') end
  return result, warning, true
end

return M
