local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local async = require('git.features.async')
local function workflow(fn, ...)
  local args = { ... }
  if async.running() then return fn(unpack(args)) end
  local done, success, result
  assert(async.run(args[1].root, function() return fn(unpack(args)) end, function(ok, value)
    success, result, done = ok, value, true
  end, { mutation = true }))
  assert(vim.wait(5000, function() return done end, 10), 'Migration timed out')
  if not success then error(result, 0) end
  return result
end
local api = setmetatable({}, { __index = function(_, name)
  local fn = require('git.features.pr_review_model')[name]
  return function(...) return workflow(fn, ...) end
end })
local migration = vim.tbl_extend('force', {}, require('git.features.pr_review_migration'))
for _, name in ipairs({ 'model', 'attach', 'prepare', 'apply' }) do
  local fn = migration[name]
  migration[name] = function(...) return workflow(fn, ...) end
end
local fixture = require('helpers.pr_fixture')
local state_dir = vim.fn.stdpath('state') .. '/git-pr-review-migrations'
local function setup()
  vim.fn.delete(state_dir, 'rf')
  local f = fixture.new()
  f.ctx = { root = f.root, host = 'ghe.example.test', repo = 'org/repo', number = 7, url = f.pr.url }
  f.old = f.head
  function f.draft(body, target)
    local c = vim.tbl_extend('force', { id = 500 + #f.pending.comments, body = body,
      path = 'file name.txt', side = 'RIGHT', line = 2, original_line = 2,
      commit_id = f.old, original_commit_id = f.old, subject_type = 'line' }, target or {})
    f.pending.comments[#f.pending.comments + 1] = c
    return c
  end
  f.pending = { id = 88, node_id = 'OLD', commit_id = f.old, state = 'PENDING',
    body = 'Summary `literal` $(not executed)\nSecond line', comments = {}, user = { login = f.viewer } }
  f.reviews = { f.pending }
  function f.push(content)
    if content then vim.fn.writefile(content, f.root .. '/file name.txt') end
    f.git({ 'add', '-u' }); f.git({ 'commit', '--allow-empty', '-qm', 'push update' })
    f.head = f.git({ 'rev-parse', 'HEAD' }); f.pr.headRefOid = f.head
    f.git({ 'update-ref', 'refs/pull/7/head', f.head })
  end
  function f.model() return migration.model(f.ctx, f.head, f.base_head) end
  function f.migrate() return api.migrate(f.ctx, f.head, f.base_head, api.load(f.ctx)) end
  function f.done(review, bodies)
    assert(review.id ~= 88 and review.commit_id == f.head and review.state == 'PENDING')
    assert(review.body == f.pending.body and #review.comments == #bodies)
    for i, body in ipairs(bodies) do assert(review.comments[i].body == body) end
    assert(not migration.load(f.ctx, f.viewer), 'Completed migration left a recovery journal')
  end
  return f
end
local function failure(fn, needle)
  local ok, err = pcall(fn)
  assert(not ok and tostring(err):find(needle, 1, true), tostring(err))
end
-- Conservative mapping includes multi-line, insertion, changed and ambiguous code.
local a, b = migration.map_lines('one\ntwo\nthree\nfour\n', 'prefix\none\ntwo\nthree\nfour\n', 2, 3)
assert(a == 3 and b == 4)
assert(not migration.map_lines('one\ntwo\nthree\n', 'one\nchanged\nthree\n', 2, 2))
assert(not migration.map_lines('a\nb\na\nb\n', 'a\nb\na\nb\na\nb\n', 2, 2))
assert(not migration.map_lines('one\ntwo\nthree\n', 'one\ntwo\ninsert\nthree\n', 2, 3))
-- All unchanged anchors, file scope and deleted-side coordinates migrate together.
local f = setup()
f.draft('Line draft')
f.draft('Range draft', { line = 3, original_line = 3, start_line = 2, original_start_line = 2, start_side = 'RIGHT' })
f.draft('File draft', { path = 'new.txt', line = vim.NIL, original_line = vim.NIL, subject_type = 'file' })
f.draft('Removed side', { side = 'LEFT' })
f.push({ 'prefix', 'one', 'TWO', 'three', 'four' })
local status, head = f.git({ 'status', '--porcelain=v1' }), f.git({ 'rev-parse', 'HEAD' })
local before_delete = false
f.api_before = function(path, method)
  if path:match('/reviews/88$') and method == 'DELETE' then
    local backup = assert(migration.load(f.ctx, f.viewer))
    assert(backup.phase == 'deleting' and #backup.items == 4 and backup.source.body == f.pending.body)
    local files = vim.fn.glob(state_dir .. '/*.json', false, true)
    assert(#files == 1 and vim.fn.getfperm(files[1]) == 'rw-------')
    before_delete = true
  end
end
local migrated = f.migrate()
f.done(migrated, { 'Line draft', 'Range draft', 'File draft', 'Removed side' })
assert(before_delete and migrated.comments[1].line == 3 and migrated.comments[2].start_line == 3 and migrated.comments[2].line == 4)
assert(migrated.comments[3].subject_type == 'file' and migrated.comments[4].side == 'LEFT' and migrated.comments[4].line == 2)
assert(f.git({ 'status', '--porcelain=v1' }) == status and f.git({ 'rev-parse', 'HEAD' }) == head)
f.cleanup()
-- Renames retain their path and content anchor.
f = setup(); f.draft('Rename draft')
f.git({ 'mv', 'file name.txt', 'renamed.txt' }); f.push()
migrated = f.migrate(); f.done(migrated, { 'Rename draft' })
assert(migrated.comments[1].path == 'renamed.txt' and migrated.comments[1].line == 2)
f.cleanup()
-- Changed and disappeared code preserve the original review until reattached.
f = setup(); local comment = f.draft('Changed code')
f.push({ 'one', 'CHANGED', 'three', 'four' })
failure(f.migrate, 'need reattachment')
assert(f.reviews[1].id == 88 and #f.reviews == 1)
local plan = assert(migration.load(f.ctx, f.viewer))
assert(migration.remaining(plan) == 1 and plan.items[1].comment.body == comment.body)
migration.attach(f.ctx, f.model(), api.load(f.ctx), comment.id, { path = 'file name.txt', side = 'RIGHT', line = 2 })
migrated = f.migrate(); f.done(migrated, { 'Changed code' })
f.cleanup()
f = setup(); f.draft('No longer in diff'); f.push({ 'one', 'two', 'three' })
failure(f.migrate, 'need reattachment'); assert(f.reviews[1].id == 88); f.cleanup()
-- An existing reply never silently becomes a new thread.
f = setup(); comment = f.draft('Reply draft', { in_reply_to_id = 101 }); f.push()
failure(f.migrate, 'need reattachment')
migration.attach(f.ctx, f.model(), api.load(f.ctx), comment.id, { path = 'file name.txt', side = 'RIGHT', line = 2 })
migrated = f.migrate(); f.done(migrated, { 'Reply draft' }); assert(not migrated.comments[1].in_reply_to_id)
f.cleanup()
-- Backup stays through every boundary; retries reconcile uncertain responses.
for _, case in ipairs({
  { stage = 'delete', after = false }, { stage = 'delete', after = true },
  { stage = 'create', after = false }, { stage = 'create', after = true },
  { stage = 'thread', after = false }, { stage = 'thread', after = true },
  { stage = 'summary', after = false }, { stage = 'summary', after = true },
}) do
  f = setup(); f.draft('First draft'); f.draft('Second draft'); f.push()
  local fired, threads = false, 0
  local function intercept(path, method)
    if fired then return end
    if path == 'graphql' then threads = threads + 1 end
    local hit = (case.stage == 'delete' and method == 'DELETE')
      or (case.stage == 'create' and path:match('/reviews$') and method == 'POST')
      or (case.stage == 'thread' and path == 'graphql' and threads == 2)
      or (case.stage == 'summary' and method == 'PUT')
    if hit then fired = true; return true end
  end
  if case.after then f.api_after = intercept else f.api_before = intercept end
  failure(f.migrate, 'server rejected write')
  assert(fired and migration.load(f.ctx, f.viewer), case.stage .. ' lost recovery copy')
  f.api_before, f.api_after = nil, nil
  -- State is recovered from disk even after the migration module is reloaded.
  package.loaded['git.features.pr_review_migration'] = nil
  migrated = f.migrate(); f.done(migrated, { 'First draft', 'Second draft' })
  f.cleanup()
end
-- Another push during partial copying re-plans ALL drafts, including uncopied ones.
f = setup(); f.draft('First draft'); f.draft('Second draft'); f.push()
local threads = 0
f.api_before = function(path)
  if path == 'graphql' then threads = threads + 1; return threads == 2 end
end
failure(f.migrate, 'server rejected write')
assert(#f.reviews[1].comments == 1)
f.api_before = nil; f.push({ 'prefix', 'one', 'TWO', 'three', 'four' })
f.reviews[1].comments[1].line = 3 -- GitHub moves displayed lines but retains original anchors.
migrated = f.migrate(); f.done(migrated, { 'First draft', 'Second draft' }); assert(migrated.comments[2].line == 3)
f.cleanup()
-- A planned manual anchor survives another push and GitHub's displayed-line drift.
f = setup(); comment = f.draft('Manual anchor'); f.push({ 'one', 'CHANGED', 'three', 'four' })
failure(f.migrate, 'need reattachment')
migration.attach(f.ctx, f.model(), api.load(f.ctx), comment.id, { path = 'file name.txt', side = 'RIGHT', line = 3 })
f.push({ 'prefix', 'one', 'CHANGED', 'three', 'four' }); f.pending.comments[1].line = 3
migrated = f.migrate(); f.done(migrated, { 'Manual anchor' }); assert(migrated.comments[1].line == 4)
f.cleanup()
-- Recovery after successful deletion + failed creation also accepts a newer head.
f = setup(); f.draft('Surviving draft'); f.push()
f.api_before = function(path, method) return path:match('/reviews$') and method == 'POST' end
failure(f.migrate, 'server rejected write'); assert(#f.reviews == 0)
f.api_before = nil; f.push({ 'one', 'CHANGED', 'three', 'four' })
failure(f.migrate, 'need reattachment')
plan = migration.load(f.ctx, f.viewer)
migration.attach(f.ctx, f.model(), api.load(f.ctx), plan.items[1].comment.id, { path = 'file name.txt', side = 'RIGHT', line = 2 })
migrated = f.migrate(); f.done(migrated, { 'Surviving draft' }); f.cleanup()
-- Normal review operations retain an old-head review, even with a blocked optional plan.
f = setup(); f.draft('Submit draft'); f.push({ 'prefix', 'one', 'TWO', 'three', 'four' })
assert(api.start(f.ctx, f.head, f.base_head).id == 88)
api.comment(f.ctx, f.head, { path = 'file name.txt', side = 'RIGHT', line = 3 }, 'Additional draft', 88, f.base_head)
assert(f.reviews[1].id == 88 and f.reviews[1].commit_id == f.old and #f.reviews[1].comments == 2)
assert(not migration.load(f.ctx, f.viewer), 'Ordinary continuation created a migration plan')
for _, call in ipairs(f.calls) do
  assert(not vim.tbl_contains(call.argv, 'DELETE'), 'Ordinary continuation deleted its review')
end
f.pending.comments[1].in_reply_to_id = 101 -- optional migration would require a new target.
plan = migration.prepare(f.ctx, f.model(), api.load(f.ctx)); assert(migration.remaining(plan) > 0)
assert(api.start(f.ctx, f.head, f.base_head).id == 88, 'An unapplied plan blocked normal resume')
api.comment(f.ctx, f.head, { path = 'file name.txt', side = 'RIGHT', line = 3 }, 'After optional preview', 88, f.base_head)
assert(f.reviews[1].id == 88 and #f.reviews[1].comments == 3, 'An unapplied plan blocked normal draft additions')
local expected = vim.deepcopy(api.load(f.ctx).pending)
api.submit(f.ctx, f.head, expected, 'COMMENT', 'Submitted summary', f.base_head)
assert(#f.reviews == 1 and f.reviews[1].id == 88 and f.reviews[1].commit_id == f.old and f.reviews[1].state == 'COMMENTED')
assert(f.reviews[1].comments[1].line == 2 and f.reviews[1].body == 'Submitted summary')
assert(not migration.load(f.ctx, f.viewer), 'Submitted review retained an obsolete optional plan')
f.cleanup()
-- After explicit migration, ordinary writes retry against the replacement ID.
f = setup(); f.draft('Existing draft'); f.push()
local captured = f.migrate()
f.api_before = function(path) return path:match('/events$') ~= nil end
local function submit_retry()
  return api.submit(f.ctx, f.head, captured, 'COMMENT', 'Retried summary', f.base_head)
end
failure(submit_retry, 'server rejected write')
assert(captured.id ~= 88 and not migration.load(f.ctx, f.viewer))
f.api_before = nil; submit_retry(); assert(f.reviews[1].state == 'COMMENTED'); f.cleanup()
f = setup(); f.draft('Existing draft'); f.push()
local captured_id = f.migrate().id
f.api_before = function(path, _, payload)
  return path == 'graphql' and payload.variables.input and payload.variables.input.body == 'New draft'
end
local function comment_retry()
  return api.comment(f.ctx, f.head, { path = 'file name.txt', side = 'RIGHT', line = 2 }, 'New draft', captured_id,
    f.base_head, function(saved) captured_id = saved.id end)
end
failure(comment_retry, 'server rejected write'); assert(captured_id ~= 88)
f.api_before = nil; comment_retry(); f.done(f.reviews[1], { 'Existing draft', 'New draft' }); f.cleanup()
-- An explicitly started but incomplete reconstruction requires manual recovery,
-- so a partially copied review is never submitted and ordinary actions never resume it.
f = setup(); f.draft('First draft'); f.draft('Second draft'); f.push()
threads = 0
f.api_before = function(path)
  if path == 'graphql' then threads = threads + 1; return threads == 2 end
end
failure(f.migrate, 'server rejected write'); f.api_before = nil
local before = #f.calls
failure(function() api.start(f.ctx, f.head, f.base_head) end, 'needs recovery')
failure(function() api.comment(f.ctx, f.head, { path = 'file name.txt', line = 2, side = 'RIGHT' }, 'New draft', f.reviews[1].id, f.base_head) end, 'needs recovery')
failure(function() api.submit(f.ctx, f.head, api.load(f.ctx).pending, 'COMMENT', 'Partial', f.base_head) end, 'needs recovery')
assert(#f.reviews[1].comments == 1 and f.reviews[1].state == 'PENDING')
for i = before + 1, #f.calls do assert(not f.calls[i].opts.stdin, 'Ordinary action resumed migration') end
migrated = f.migrate(); f.done(migrated, { 'First draft', 'Second draft' }); f.cleanup()
-- Unseen edits/submission/another pending review cannot be adopted on retry.
f = setup(); f.draft('Protected draft'); f.push()
f.api_before = function(path, method) return method == 'DELETE' end
failure(f.migrate, 'server rejected write'); f.api_before = nil
f.reviews[1].comments[1].body = 'External edit'
failure(f.migrate, 'Pending review changed'); assert(f.reviews[1].id == 88)
f.cleanup()
f = setup(); f.draft('Protected draft'); f.push()
f.api_before = function(path, method) return method == 'DELETE' end
failure(f.migrate, 'server rejected write'); f.api_before = nil
f.reviews[1].state = 'COMMENTED'
failure(f.migrate, 'submitted externally'); assert(#f.reviews == 1)
f.cleanup()
f = setup(); f.draft('Protected draft'); f.push()
f.api_before = function(path, method) return path:match('/reviews$') and method == 'POST' end
failure(f.migrate, 'server rejected write'); f.api_before = nil
f.reviews[1] = { id = 90, node_id = 'UNRELATED', commit_id = f.head, body = 'Unrelated', state = 'PENDING', comments = {}, user = { login = f.viewer } }
failure(f.migrate, 'different pending review'); assert(f.reviews[1].id == 90)
f.cleanup()
-- Actual gr u preview/apply and gC m reattachment remain usable on the panel.
f = setup(); f.draft('UI draft'); f.push({ 'one', 'CHANGED', 'three', 'four' })
local ui = require('helpers.pr_ui').new(f)
ui.open(); ui.menu('gr'); ui.key('u')
ui.wait(function() return vim.fn.maparg('p', 'n', false, true).callback ~= nil and migration.load(f.ctx, f.viewer) ~= nil end)
ui.key('p')
assert(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find('UI draft', 1, true))
ui.key('q'); ui.source()
ui.key('>', ui.row('Changes (')); ui.wait(function() return pcall(ui.row, '+CHANGED') end)
vim.ui.select = function(items, _, callback) callback(items[1]) end
ui.key('gC', ui.row('+CHANGED')); ui.key('m')
ui.wait(function() local saved = migration.load(f.ctx, f.viewer); return saved and migration.remaining(saved) == 0 end)
assert(f.reviews[1].id == 88, 'Reattachment changed GitHub before applying')
ui.menu('gr'); ui.key('u')
ui.wait(function() return vim.fn.maparg('a', 'n', false, true).callback ~= nil and vim.fn.maparg('p', 'n', false, true).callback ~= nil end)
ui.key('a'); ui.wait(function() return not migration.load(f.ctx, f.viewer) end); ui.loaded()
f.done(f.reviews[1], { 'UI draft' }); f.cleanup()
print('PR review migration checks passed')
