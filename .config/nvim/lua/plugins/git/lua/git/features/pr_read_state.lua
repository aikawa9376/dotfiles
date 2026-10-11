-- Local read receipts belong to a GitHub viewer, not a checkout or PR revision.
-- One file per comment avoids losing another instance's receipts when merging.
local M = {}
local function path(ctx, viewer, comment)
  local key = vim.fn.sha256(table.concat({ ctx.host, ctx.repo, tostring(ctx.number), viewer }, '/'))
  return vim.fn.stdpath('state') .. '/git-pr-comment-reads/' .. key .. '/' .. vim.fn.sha256(tostring(comment.id))
end
local function fingerprint(comment)
  return vim.fn.sha256(vim.json.encode({ body = comment.body or '', updated_at = require('git.features.github').scalar(comment.updated_at) }))
end
local function received(viewer, comment)
  return viewer and not comment.pending and comment.user and comment.user.login and comment.user.login ~= viewer
end
function M.unread(ctx, viewer, threads)
  local unread = {}
  for _, thread in ipairs(threads) do for _, comment in ipairs(thread.comments) do
    if received(viewer, comment) then
      local ok, lines = pcall(vim.fn.readfile, path(ctx, viewer, comment))
      unread[comment.id] = not ok or lines[1] ~= fingerprint(comment)
    end
  end end
  return unread
end
function M.mark(ctx, viewer, comments)
  if not viewer then return end
  for _, comment in ipairs(comments) do if received(viewer, comment) then
    local target = path(ctx, viewer, comment)
    vim.fn.mkdir(vim.fs.dirname(target), 'p', 448)
    local tmp = target .. '.' .. tostring(vim.uv.hrtime())
    local fd = assert(vim.uv.fs_open(tmp, 'wx', 384))
    local body = fingerprint(comment) .. '\n'
    local ok, err = pcall(function() assert(vim.uv.fs_write(fd, body, 0) == #body) end)
    vim.uv.fs_close(fd)
    if not ok then vim.uv.fs_unlink(tmp); error(err, 0) end
    local renamed, failure = vim.uv.fs_rename(tmp, target)
    if not renamed then vim.uv.fs_unlink(tmp); error(failure, 0) end
  end end
  vim.api.nvim_exec_autocmds('User', { pattern = 'GitPrCommentsRead', data = vim.tbl_extend('force', ctx, { viewer = viewer }) })
end
return M
