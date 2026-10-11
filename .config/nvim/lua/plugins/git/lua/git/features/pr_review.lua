local M = {}
local api = require('git.features.pr_review_model')
local actions = require('git.features.github_actions')
local composer = require('git.features.pr_composer')
local location = require('git.features.pr_comment_location').format
function M.target(buf, first, last)
  local view = require('git.features.pr')
  local entry, info = view.entry_at(buf, first)
  if not entry then return nil end
  if first == last and info.header then return { path = entry.path } end
  local coordinates, right, left = {}, true, true
  for row = first, last do
    local item, at = view.entry_at(buf, row)
    if not item or item.path ~= entry.path or not at.coordinate then return nil, 'Select diff lines in one file, or its header for a file comment' end
    coordinates[#coordinates + 1] = at.coordinate
    right, left = right and at.coordinate.right ~= nil, left and at.coordinate.left ~= nil
  end
  if not right and not left then return nil, 'Select lines on one diff side; additions and deletions cannot share a comment range' end
  local side, name = right and 'RIGHT' or 'LEFT', right and 'right' or 'left'
  local start, finish = coordinates[1][name], coordinates[#coordinates][name]
  if finish - start + 1 ~= #coordinates then return nil, 'Select a continuous range on one diff side' end
  return { path = entry.path, line = finish, side = side,
    start_line = first ~= last and start or nil, start_side = first ~= last and side or nil }
end
function M.new_comment(model, target, opts)
  opts = opts or {}
  -- Capture revision, target and existing review identity before opening a menu.
  local ctx, hash = vim.deepcopy(model.ctx), model.hash
  local base = model.pr.baseRefOid
  target = target and vim.deepcopy(target)
  local pending = model.review and model.review.pending
  local id = pending and pending.id
  local function open(review, general)
    local at = not general and target or nil
    local label = general and 'PR comment' or review and 'Review draft comment' or 'Diff comment'
    return composer.open({ ctx = ctx, title = label,
      prefix = { 'PR #' .. ctx.number .. ' · ' .. (at and location(at) or 'Conversation'),
        '', at and ('Head: ' .. hash:sub(1, 7)) or ctx.url },
      action = review and 'save' or 'post',
      success = review and 'Comment saved to pending review' or 'Comment posted',
      submit = function(resolved, body)
        if review then return api.comment(resolved, hash, at, body, id, base, function(saved) id = saved.id end) end
        return api.comment(resolved, hash, at, body, false, base)
      end,
    })
  end
  if opts.destination then
    if opts.destination == 'p' or (opts.destination == 'c' and not target) then return open(false, true) end
    if not target then vim.notify('Select a PR diff line or file for a review draft', vim.log.levels.WARN); return end
    return open(opts.destination == 'r')
  end
  return require('git.features.transient_menu').show({ kind = 'pr-comment', title = 'New PR comment',
    context = target and location(target) or ctx.url, groups = { { title = 'Comment destination', actions = {
      { key = 'p', label = 'PR conversation · post immediately', run = function() open(false, true) end },
      { key = 'c', label = 'Diff comment · post immediately', enabled = target ~= nil, run = function() open(false) end },
      { key = 'r', label = 'Diff comment · save to pending review', enabled = target ~= nil, run = function() open(true) end },
      { key = 'm', label = 'Choose a migration target for a saved draft', enabled = target ~= nil and model.review ~= nil
        and (model.review.migration ~= nil or (pending ~= nil and pending.commit_id ~= hash)),
        run = function() M.reattach(model, target) end },
    } } } })
end
local function in_source(win, buf)
  return vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf and vim.api.nvim_get_current_win() == win
end
function M.reattach(model, target)
  local migration = require('git.features.pr_review_migration')
  local ctx, at = vim.deepcopy(model.ctx), vim.deepcopy(target)
  ctx.notify_change = false
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  actions.run(ctx, function(resolved)
    api.check_head(resolved, model.hash, model.pr.baseRefOid)
    return migration.prepare(resolved, model, api.load(resolved))
  end, function(result)
    if not in_source(win, buf) then return end
    vim.ui.select(result.items, { prompt = 'Reattach draft to ' .. location(at), format_item = function(item)
      return (item.target and '[mapped] ' or '[needs target] ') .. item.comment.path .. ' · ' .. item.comment.body:gsub('[\r\n]', ' ')
    end }, function(item)
      if not item or not in_source(win, buf) then return end
      if require('git.features.github').scalar(item.comment.in_reply_to_id)
        and vim.fn.confirm('Move this reply draft into a new review thread at ' .. location(at) .. '?', '&Move\n&Keep', 2) ~= 1 then return end
      actions.run(ctx, function(resolved)
        api.check_head(resolved, model.hash, model.pr.baseRefOid)
        local state = api.load(resolved)
        local latest = migration.prepare(resolved, model, state)
        local found
        for _, candidate in ipairs(latest.items) do
          if candidate.comment.id == item.comment.id and candidate.comment.body == item.comment.body then found = true end
        end
        assert(found, 'Draft changed; reopen migration before reattaching')
        return migration.attach(resolved, model, state, item.comment.id, at)
      end, function() vim.notify('Draft reattached; gr u previews / applies the migration') end,
        true)
    end)
  end, true)
end
function M.migration_menu(model)
  local migration = require('git.features.pr_review_migration')
  local ctx = vim.deepcopy(model.ctx)
  ctx.notify_change = false
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  actions.run(ctx, function(resolved)
    api.check_head(resolved, model.hash, model.pr.baseRefOid)
    local state = api.load(resolved)
    local ok, result = pcall(migration.prepare, resolved, model, state)
    if not ok then
      if not state.migration then error(result, 0) end
      local preserved = vim.deepcopy(state.migration)
      preserved.warning = tostring(result)
      return preserved
    end
    return result
  end, function(result)
    if not in_source(win, buf) then return end
    local remaining = migration.remaining(result)
    require('git.features.transient_menu').show({ kind = 'pr-review-migration', title = 'Review migration',
      context = ('%d drafts · %d need a target · %s'):format(#result.items, remaining, model.hash:sub(1, 7)),
      groups = { { title = 'Migration', actions = {
        { key = 'p', label = 'Preview preserved drafts / target positions', run = function()
          local lines = { 'Review migration', '', 'Summary' }
          if result.warning then vim.list_extend(lines, { result.warning, '' }) end
          vim.list_extend(lines, vim.split(result.summary or result.source.body, '\n', { plain = true }))
          vim.list_extend(lines, { '', 'Draft comments' })
          for _, item in ipairs(result.items) do
            lines[#lines + 1] = item.target and ('→ ' .. location(item.target)) or ('? ' .. item.comment.path .. ' · ' .. item.reason)
            vim.list_extend(lines, vim.split(item.comment.body, '\n', { plain = true }))
            lines[#lines + 1] = ''
          end
          vim.list_extend(lines, { 'Choose a current diff line / file and gC m to reattach unresolved drafts.',
            'Drafts stay in a private recovery file until the replacement is verified.' })
          require('git.features.help').show_text('Review migration', lines, { headings = { Summary = true, ['Draft comments'] = true } })
        end },
        { key = 'a', label = 'Apply / resume migration', enabled = remaining == 0 and not result.warning, run = function()
          local apply_ctx = vim.deepcopy(ctx); apply_ctx.notify_change = nil
          actions.run(apply_ctx, function(resolved) return api.migrate(resolved, model.hash, model.pr.baseRefOid, api.load(resolved)) end,
            function(review) vim.notify('Review #' .. review.id .. ' migrated to current head') end, true)
        end },
      } } } })
  end, true)
end
function M.edit(ctx, id, comment)
  comment = vim.deepcopy(comment)
  return composer.open({ ctx = ctx, title = 'Edit review draft', body = comment.body,
    prefix = { 'PR #' .. ctx.number .. ' · Review #' .. id, location({ path = comment.path,
      line = require('git.features.github').scalar(comment.line), side = comment.side,
      start_line = require('git.features.github').scalar(comment.start_line) }), '' },
    action = 'save', success = 'Review draft updated',
    submit = function(resolved, body) return api.edit(resolved, id, comment, body) end,
    delete_prompt = ('Delete pending comment #%d on %s and discard local edits?'):format(comment.id, comment.path),
    delete = function(resolved) return api.remove(resolved, id, comment) end,
  })
end
function M.drafts(ctx, pending)
  if not pending or #pending.comments == 0 then vim.notify('No pending review comments'); return end
  local comments = vim.deepcopy(pending.comments)
  if #comments == 1 then return M.edit(ctx, pending.id, comments[1]) end
  vim.ui.select(comments, { prompt = 'Pending review comments · select to edit', format_item = function(comment)
    return comment.path .. ' · ' .. (comment.body or ''):gsub('[\r\n]', ' ')
  end }, function(comment) if comment then M.edit(ctx, pending.id, comment) end end)
end
function M.menu(model, opts)
  opts = opts or {}
  local ctx, hash = vim.deepcopy(model.ctx), model.hash
  local base = model.pr.baseRefOid
  local source_win, source_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  local _, info = require('git.features.pr').entry_at(source_buf, vim.fn.line('.'))
  local threads = vim.deepcopy(info and info.threads or model.threads)
  return actions.run(ctx, api.load, function(state)
    if not vim.api.nvim_win_is_valid(source_win) or vim.api.nvim_win_get_buf(source_win) ~= source_buf
      or vim.api.nvim_get_current_win() ~= source_win then return end
    local pending = state.pending
    local function start(done)
      actions.run(ctx, function(resolved) return api.start(resolved, hash, base) end, done, true)
    end
    local function summary(review)
      composer.open({ ctx = ctx, title = 'Review summary draft', body = review.body or '', allow_empty = true,
        prefix = { 'PR #' .. ctx.number .. ' · Review #' .. review.id, '' },
        action = 'save', success = 'Review summary saved',
        submit = function(resolved, body) return api.summary(resolved, review.id, review.body or '', body) end,
      })
    end
    local function submit(event)
      local labels = { APPROVE = 'Approve', REQUEST_CHANGES = 'Request changes', COMMENT = 'Submit comments' }
      local hint = (event == 'APPROVE' or (event == 'COMMENT' and pending and #pending.comments > 0))
        and 'summary optional' or 'summary required'
      composer.open({ ctx = ctx, title = labels[event] .. ' · review', body = pending and pending.body or '', allow_empty = true,
        prefix = { 'PR #' .. ctx.number .. ' · ' .. labels[event], 'Head: ' .. hash:sub(1, 7),
          ('Pending comments: %d'):format(pending and #pending.comments or 0), '' },
        action = event == 'APPROVE' and 'approve' or 'submit', hint = hint, success = 'Review submitted: ' .. labels[event],
        submit = function(resolved, body) return api.submit(resolved, hash, pending, event, body, base) end,
      })
    end
    if opts.submit then return submit(opts.submit) end
    local status = pending and ('Review #%d · %d draft comments · review commit %s'):format(pending.id, #pending.comments,
      pending.commit_id:sub(1, 7)) or 'No pending review'
    require('git.features.transient_menu').show({ kind = 'pr-review', title = 'PR review', context = status,
      groups = {
        { title = 'Draft', actions = {
          { key = 's', label = 'Start / resume review', run = function() start(function(review)
            vim.notify('Pending review #' .. review.id .. ' ready')
            -- A delayed request must not steal focus from another window.
            if vim.api.nvim_get_current_win() == source_win and vim.api.nvim_win_get_buf(source_win) == source_buf then M.menu(model) end
          end) end },
          { key = 'c', label = 'Read / edit draft comments', enabled = pending ~= nil, run = function() M.drafts(ctx, pending) end },
          { key = 'u', label = 'Move drafts to current head / recover migration',
            enabled = (pending ~= nil and pending.commit_id ~= hash) or state.migration ~= nil,
            run = function() M.migration_menu(model) end },
          { key = 'b', label = 'Edit review summary draft', run = function()
            if pending then summary(pending) else start(function(review)
              if vim.api.nvim_win_is_valid(source_win) and vim.api.nvim_get_current_win() == source_win
                and vim.api.nvim_win_get_buf(source_win) == source_buf then summary(review) end
            end) end
          end },
        } },
        { title = 'Submit', actions = {
          { key = 'a', label = 'Approve…', run = function() submit('APPROVE') end },
          { key = 'r', label = 'Request changes…', run = function() submit('REQUEST_CHANGES') end },
          { key = 'm', label = 'Submit comments…', run = function() submit('COMMENT') end },
        } },
        { title = 'Threads', actions = {
          { key = 'R', label = 'Resolve / reopen selected thread',
            enabled = #vim.tbl_filter(function(thread) return not thread.pending end, threads) > 0,
            run = function() require('git.features.pr_thread_status').toggle(ctx, threads) end },
        } },
        { title = 'Other', actions = {
          { key = 'x', label = 'Discard pending review…', enabled = pending ~= nil, run = function()
            if vim.fn.confirm('Discard pending review #' .. pending.id .. ' and all its draft comments?', '&Discard\n&Keep', 2) ~= 1 then return end
            actions.run(ctx, function(resolved) return api.discard(resolved, pending) end,
              function() vim.notify('Pending review discarded') end, true)
          end },
          { key = 'o', label = 'Continue in Octo', run = function() actions.octo(ctx, true) end },
        } },
      } })
  end)
end
return M
