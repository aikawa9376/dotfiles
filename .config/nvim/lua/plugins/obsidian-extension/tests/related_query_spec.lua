local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
local related = require('obsidian_extension.features.related')
local context = require('obsidian_extension.context')
local roots = { vim.fn.tempname(), vim.fn.tempname() }
local function note(root, path, lines)
  path = root .. '/' .. path
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  vim.fn.writefile(lines, path)
end
for _, root in ipairs(roots) do
  note(root, 'notes/projects/example/feature/test.md', {
    '---', 'project: example', 'branch: feature/test', '---', '# Branch', '[[guide]]',
  })
  note(root, 'notes/guide.md', { '# Guide' })
  note(root, 'notes/project.md', { '---', 'project: example', '---', '# Project' })
  note(root, 'notes/unrelated.md', { '---', 'project: other', '---', '# Unrelated' })
end
local ctx = context.for_repository('/captured/example', 'feature/test')
assert(ctx.repo_slug == 'example' and ctx.branch_note_segments[2] == 'test')
local a, b
related.query({ root = roots[1], git_context = ctx, min_score = 1 }, function(result, err) assert(not err); a = result end)
related.query({ root = roots[2], git_context = ctx, min_score = 1, limit = 2 }, function(result, err) assert(not err); b = result end)
assert(vim.wait(5000, function() return a and b end, 10))
assert(#a == 3 and #b == 2, 'Context filtering/limit did not remove unrelated notes')
assert(a[1].entry.title == 'Branch' and vim.tbl_contains(a[1].reasons, 'branch'))
assert(vim.tbl_contains(a[1].reasons, 'branch_note') and a[1].score == 350)
assert(a[1].entry.mtime == vim.uv.fs_stat(a[1].entry.path).mtime.sec, 'Index should share the actual note modification time')
assert(a[3].entry.title == 'Guide' and vim.tbl_contains(a[3].reasons, 'linked'), 'Shared ranking lost branch-note links')
for _, candidate in ipairs(a) do assert(candidate.entry.path:sub(1, #roots[1]) == roots[1]) end
for _, candidate in ipairs(b) do assert(candidate.entry.path:sub(1, #roots[2]) == roots[2]) end
local cancelled_called, done = false, false
local stop = related.query({ root = roots[1], git_context = ctx }, function() cancelled_called = true end)
stop()
related.query({ root = roots[1], git_context = false }, function(result)
  assert(#result == 4, 'Picker fallback should still include every note')
  done = true
end)
assert(vim.wait(5000, function() return done end, 10))
assert(not cancelled_called, 'Cancelled consumer still received shared-index results')
-- Every query rescans names while reusing unchanged note parsing.
vim.fn.delete(roots[1] .. '/notes/project.md')
local remaining
related.query({ root = roots[1], git_context = ctx, min_score = 1 }, function(result) remaining = result end)
assert(vim.wait(5000, function() return remaining end, 10))
assert(#remaining == 2, 'Deleted notes remained in the shared index')
-- Recency selects the shortlist among equally relevant project notes.
note(roots[1], 'notes/older.md', { '---', 'project: example', '---', '# A older note' })
note(roots[1], 'notes/newer.md', { '---', 'project: example', '---', '# Z newer note' })
assert(vim.uv.fs_utime(roots[1] .. '/notes/older.md', 100, 100))
assert(vim.uv.fs_utime(roots[1] .. '/notes/newer.md', 200, 200))
local ordered
related.query({ root = roots[1], git_context = ctx, min_score = 1, limit = 2 }, function(result) ordered = result end)
assert(vim.wait(5000, function() return ordered end, 10))
assert(ordered[1].entry.title == 'Branch', 'Date must retain the stronger branch association')
assert(ordered[2].entry.title == 'Z newer note', 'Recent project notes should win over alphabetical order before limiting')
assert(vim.uv.fs_utime(roots[1] .. '/notes/older.md', 300, 300))
ordered = nil
related.query({ root = roots[1], git_context = ctx, min_score = 1, limit = 2 }, function(result) ordered = result end)
assert(vim.wait(5000, function() return ordered end, 10))
assert(ordered[2].entry.title == 'A older note', 'An updated note should move forward after refreshing the shared index')
local failure
related.query({ root = '/missing-obsidian-vault-for-test', git_context = ctx }, function(result, err)
  assert(result == nil)
  failure = err
end)
assert(vim.wait(5000, function() return failure end, 10), 'Index errors must complete embedding callbacks')
for _, root in ipairs(roots) do vim.fn.delete(root, 'rf') end
print('ok - related_query_spec: shared ranking, vault isolation, linked notes, limits, cancellation, deletion and errors')
