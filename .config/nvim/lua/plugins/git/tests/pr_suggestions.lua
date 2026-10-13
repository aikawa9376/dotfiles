local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.pr_fixture').new()
local api = require('git.features.pr_suggestions')
local ctx = { root = f.root, host = 'ghe.example.test', repo = 'org/repo', number = 7, url = f.pr.url }
local function run(fn)
  local done, ok, value
  require('git.features.async').run(f.root, fn, function(success, result) done, ok, value = true, success, result end)
  assert(vim.wait(5000, function() return done end, 10)); return ok, value
end
local function succeed(fn) local ok, result = run(fn); assert(ok, result); return result end
local item = { id = 101, body = 'Please change\n```suggestion\nnew TWO\n```', path = 'file name.txt', side = 'RIGHT', line = 2 }
local mutation, reject
f.api_response = function(path, method, payload)
  if path == 'repos/org/repo/pulls/comments/101' then return { data = vim.deepcopy(item) }
  elseif path == 'repos/org/repo/pulls/7' then
    return { data = { head = { sha = f.pr.headRefOid, repo = { full_name = 'fork/repo' }, ref = 'topic' } } }
  elseif path == 'graphql' and payload.query:find('createCommitOnBranch', 1, true) then
    mutation = payload.variables.input
    return { data = reject and { errors = { { message = 'Head changed' } } }
      or { data = { createCommitOnBranch = { commit = { oid = 'new-commit', url = 'https://example.test/commit' } } } } }
  end
end
local suggestions = api.parse(item.body); assert(#suggestions == 1)
local plan = succeed(function() return api.prepare(ctx, item, suggestions[1]) end)
assert(plan.replacement == 'one\nnew TWO\nthree\nfour\n')
local head = f.git({ 'rev-parse', 'HEAD' })
local dirty = table.concat(vim.fn.readfile(f.root .. '/dirty.txt'), '\n')
succeed(function() return api.local_apply(plan) end)
assert(table.concat(vim.fn.readfile(f.root .. '/file name.txt'), '\n') == 'one\nnew TWO\nthree\nfour')
assert(f.git({ 'rev-parse', 'HEAD' }) == head and f.git({ 'diff', '--cached', '--name-only' }) == '')
assert(table.concat(vim.fn.readfile(f.root .. '/dirty.txt'), '\n') == dirty)
assert(not run(function() return api.local_apply(plan) end), 'Repeated local apply should not overwrite local changes')
vim.fn.writefile({ 'one', 'TWO', 'three', 'four' }, f.root .. '/file name.txt')
local target = vim.fn.bufadd(f.root .. '/file name.txt'); vim.fn.bufload(target)
vim.api.nvim_buf_set_lines(target, 1, 2, false, { 'Unsaved target' })
assert(not run(function() return api.local_apply(plan) end), 'An unsaved target must be preserved')
vim.api.nvim_buf_delete(target, { force = true })
vim.fn.writefile({ 'one', 'staged', 'three', 'four' }, f.root .. '/file name.txt'); f.git({ 'add', 'file name.txt' })
assert(not run(function() return api.local_apply(plan) end), 'A staged target must be preserved')
f.git({ 'restore', '--staged', 'file name.txt' }); vim.fn.writefile({ 'one', 'TWO', 'three', 'four' }, f.root .. '/file name.txt')
local result = succeed(function() return api.remote_apply(plan, 'Apply suggestion\n\nReason') end)
assert(result.oid == 'new-commit' and mutation.expectedHeadOid == f.head)
assert(mutation.branch.repositoryNameWithOwner == 'fork/repo' and mutation.branch.branchName == 'topic')
assert(vim.base64.decode(mutation.fileChanges.additions[1].contents) == plan.replacement)
assert(mutation.message.headline == 'Apply suggestion' and mutation.message.body == '\nReason')
reject = true; assert(not run(function() return api.remote_apply(plan, 'Apply') end))
reject = nil; f.pr.headRefOid = f.base
assert(not run(function() return api.remote_apply(plan, 'Apply') end), 'Head changes must reject the old plan')
f.pr.headRefOid = f.head
local range = api.parse('```suggestion:-1+1\nrange replacement\n```')[1]
assert(range.before == 1 and range.after == 1)
assert(api.replace('a\r\nb\r\nc\r\n', { line = 2, side = 'RIGHT' }, range) == 'range replacement\r\n')
assert(api.replace('a\nb', { line = 2, side = 'RIGHT' }, { lines = { 'B' } }) == 'a\nB')
assert(api.replace('a\nb\n', { line = 2, side = 'RIGHT' }, { lines = {} }) == 'a\n')
assert(#api.parse('```text\n```suggestion\nnot a suggestion\n```\n```') == 0)
assert(not pcall(api.replace, 'a\n', { line = 1, side = 'LEFT' }, suggestions[1]))
assert(not pcall(api.replace, 'a\n', { line = 2, side = 'RIGHT' }, suggestions[1]))
item.line = vim.NIL; assert(not run(function() return api.prepare(ctx, item, suggestions[1]) end), 'Outdated suggestions must not use old line coordinates')
f.cleanup()
print('PASS: local application, unchanged index/head/other edits, dirty/staged/unsaved guards, fork commit/CAS payload, remote rejection, fences/ranges/CRLF/EOF and outdated anchors')
