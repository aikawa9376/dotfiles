local M = {}

local function run(root, args, stdin)
  local argv = { 'git', '-C', root }
  vim.list_extend(argv, args)
  return vim.system(argv, { text = true, stdin = stdin }):wait()
end

local function read_patch(root, args, target)
  vim.list_extend(args, { '--no-color', '--no-ext-diff', '--no-textconv',
    '--src-prefix=a/', '--dst-prefix=b/', '--binary', '--full-index' })
  vim.list_extend(args, target)
  return run(root, args)
end

-- Magit's regular apply/reverse writes a displayed committed/staged patch to the worktree.
-- Git's three-way fallback also updates the index, as in Magit.
function M.apply(ctx, three_way, reverse)
  if not ctx.work_tree then return false, 'No repository selected' end
  local source
  if ctx.patch then
    source = { code = 0, stdout = ctx.patch }
  elseif ctx.commit then
    local parents = run(ctx.work_tree, { 'rev-list', '--parents', '-n1', ctx.commit })
    if parents.code ~= 0 then return false, vim.trim(parents.stderr) end
    if #vim.split(vim.trim(parents.stdout), ' ', { plain = true }) > 2 then
      return false, 'Select a non-merge commit to apply its patch'
    end
    source = read_patch(ctx.work_tree, { 'show', '--root', '--format=' }, { ctx.commit, '--' })
  elseif ctx.panel == 'status' and ctx.path and ctx.section == 'staged' then
    if ctx.hunk then
      local patch, err = require('git.features.status_patch').build_patch(ctx.work_tree,
        'staged', ctx.path, ctx.hunk.number, {}, ctx.hunk.expected, false)
      if not patch then return false, err end
      source = { code = 0, stdout = patch }
    else
      source = read_patch(ctx.work_tree, { 'diff', '--cached' }, { '--', ctx.path })
    end
  else
    return false, 'Select a commit or a staged file to apply'
  end
  if source.code ~= 0 then return false, vim.trim(source.stderr) end
  if source.stdout == '' then return false, 'Selected patch is empty' end
  local args = { 'apply' }
  if three_way then
    -- A previous worktree-only reverse can leave cached index stat data stale.
    run(ctx.work_tree, { 'update-index', '-q', '--refresh' })
    args[#args + 1] = '--3way'
  end
  if reverse then args[#args + 1] = '--reverse' end
  local result = run(ctx.work_tree, args, source.stdout)
  -- Three-way apply can leave real conflicts even when Git exits nonzero.
  require('git.utils').fire_fugitive_changed({ work_tree = ctx.work_tree })
  if result.code ~= 0 then return false, vim.trim(result.stderr) end
  return true
end

function M.context(bufnr, row, revision)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end
  row = row or vim.api.nvim_win_get_cursor(0)[1]
  local utils = require('git.utils')
  local root = utils.get_buf_work_tree(bufnr) or utils.get_work_tree({})
  if revision and revision ~= '' then
    return { work_tree = root, commit = revision }
  end
  if vim.bo[bufnr].filetype == 'fugitivecommit' then
    local view = require('git.features.commit')
    local model = view.model(bufnr)
    if not model then return nil, 'Commit view is no longer available' end
    local entry, info = view.entry_at(bufnr, row)
    if not entry then return { work_tree = model.root, commit = model.hash } end
    local patch, err = require('git.features.commit_model').patch(model, entry)
    if not patch then return nil, err end
    if info and info.patch_row then
      local hunk
      for index = info.patch_row, 1, -1 do
        if patch[index]:match('^@@') then hunk = index; break end
      end
      if hunk then
        patch = require('git.features.commit_patch').hunk(patch, hunk)
      end
    end
    return { work_tree = model.root, patch = table.concat(patch, '\n') .. '\n' }
  end
  local ctx = require('git.features.magit_actions').context(bufnr, row)
  if ctx and (ctx.commit or (ctx.panel == 'status' and ctx.section == 'staged')) then
    return ctx
  end
  return nil, 'Select a commit, staged file, or displayed hunk, or pass a revision'
end

function M.setup()
  for _, spec in ipairs({ { name = 'GitApply', reverse = false },
    { name = 'GitReverse', reverse = true } }) do
    vim.api.nvim_create_user_command(spec.name, function(opts)
      local ctx, err = M.context(0, nil, opts.args)
      if not ctx then vim.notify(err, vim.log.levels.ERROR); return end
      local ok, apply_err = M.apply(ctx, opts.bang, spec.reverse)
      if not ok then vim.notify(apply_err, vim.log.levels.ERROR) end
    end, { nargs = '?', bang = true, complete = require('git.completion').refs,
      desc = spec.reverse and 'Reverse selected Git patch in worktree'
        or 'Apply selected Git patch to worktree' })
  end
end

return M
