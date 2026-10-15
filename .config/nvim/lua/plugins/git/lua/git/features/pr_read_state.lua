-- Local read receipts belong to a GitHub viewer, not a checkout or PR revision.
-- One file per comment avoids losing another instance's receipts when merging.
local M = {}
local function identity(comment)
  -- Keep existing inline receipts; issue comments/reviews can share their
  -- numeric IDs and timeline events have their own immutable node keys.
  if comment.key then return comment.key end
  if comment.kind and comment.kind ~= 'inline' then return comment.kind .. ':' .. tostring(comment.id) end
  return tostring(comment.id)
end
local function path(ctx, viewer, comment)
  local key = vim.fn.sha256(table.concat({ ctx.host, ctx.repo, tostring(ctx.number), viewer }, '/'))
  return vim.fn.stdpath('state') .. '/git-pr-comment-reads/' .. key .. '/' .. vim.fn.sha256(identity(comment))
end
local function fingerprint(comment)
  -- Object key iteration depends on Lua's process hash seed. Positional
  -- fields have one encoding across editor restarts and API table layouts.
  local updated = require('git.features.github').scalar(comment.updated_at)
  return 'v2:' .. vim.fn.sha256(vim.json.encode({ comment.body or '', updated or vim.NIL, comment.review_state or vim.NIL }))
end
local function legacy_matches(saved, comment)
  if not saved or #saved ~= 64 or not saved:match('^%x+$') then return false end
  local fields = { '"body":' .. vim.json.encode(comment.body or '') }
  local updated = require('git.features.github').scalar(comment.updated_at)
  if updated then fields[#fields + 1] = '"updated_at":' .. vim.json.encode(updated) end
  if comment.review_state then fields[#fields + 1] = '"review_state":' .. vim.json.encode(comment.review_state) end
  -- Old receipts only contain a digest. Accept the at most six historical
  -- object orders, without treating a changed body/date/review state as read.
  local function matches(first)
    if first > #fields then return saved == vim.fn.sha256('{' .. table.concat(fields, ',') .. '}') end
    for index = first, #fields do
      fields[first], fields[index] = fields[index], fields[first]
      local found = matches(first + 1)
      fields[first], fields[index] = fields[index], fields[first]
      if found then return true end
    end
    return false
  end
  return matches(1)
end
local function received(viewer, comment)
  return viewer and not comment.pending and comment.user and comment.user.login and comment.user.login ~= viewer
end
local function is_unread(ctx, viewer, comment)
  if not received(viewer, comment) then return false end
  local ok, lines = pcall(vim.fn.readfile, path(ctx, viewer, comment))
  if not ok then return true end
  return lines[1] ~= fingerprint(comment) and not legacy_matches(lines[1], comment)
end
function M.unread(ctx, viewer, threads)
  local unread = {}
  for _, thread in ipairs(threads) do for _, comment in ipairs(thread.comments) do
    if received(viewer, comment) then unread[comment.id] = is_unread(ctx, viewer, comment) end
  end end
  return unread
end
function M.unread_entries(ctx, viewer, entries)
  local result = {}
  for _, entry in ipairs(entries) do result[entry.key or entry.id] = is_unread(ctx, viewer, entry) end
  return result
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
