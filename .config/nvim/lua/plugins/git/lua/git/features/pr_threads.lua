-- Existing review threads, including outdated/file comments, with a reply draft.
local M = {}
local github = require('git.features.github')
function M.open(ctx, thread, viewer)
  if thread.pending then return require('git.features.pr_review').drafts(ctx,
    { id = thread.review_id, comments = thread.comments }) end
  local buf = require('git.features.pr_composer').open({
    ctx = ctx, title = 'PR thread / reply', history = thread.comments, viewer = viewer,
    prefix = { ('PR #%d · %s%s'):format(ctx.number, thread.path,
      thread.line and (':' .. thread.line .. ' (' .. (thread.side or 'RIGHT') .. ')') or ' (file / outdated)'), '' },
    instruction = 'Reply below; <C-s> / :w sends to GitHub · Tab reads history', success = 'Reply sent',
    submit = function(resolved, body)
      return github.api(resolved, ('repos/%s/pulls/%d/comments/%d/replies'):format(resolved.repo, resolved.number, thread.id), { body = body })
    end,
  })
  if vim.b[buf].git_pr_history then
    local ok, err = pcall(require('git.features.pr_read_state').mark, ctx, viewer, thread.comments)
    if not ok then vim.notify('Could not save comment read state: ' .. tostring(err), vim.log.levels.WARN) end
  end
  return buf
end
function M.select(ctx, threads, viewer)
  if #threads == 0 then vim.notify('No review comments here'); return end
  if #threads == 1 then return M.open(ctx, threads[1], viewer) end
  vim.ui.select(threads, { prompt = 'Review threads', format_item = function(thread)
    local comment = thread.comments[1]
    local marker = thread.pending and '📝 [pending] ' or thread.has_pending and '💬 + 📝 [pending] ' or '💬 '
    return marker .. ('%s%s · @%s: %s'):format(thread.path, thread.line and (':' .. thread.line) or ' (file / outdated)',
      comment.user and comment.user.login or 'unknown', (comment.body or ''):gsub('[\r\n]', ' '))
  end }, function(thread) if thread then M.open(ctx, thread, viewer) end end)
end
return M
