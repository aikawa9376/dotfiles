local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.pr_fixture').new()
local ui = require('helpers.pr_ui').new(f)
local view, async = require('git.features.pr'), require('git.features.async')
local system = vim.system
local git_calls, active, peak = {}, 0, 0
vim.system = function(argv, opts, callback)
  if argv[1] == 'git' then
    git_calls[#git_calls + 1] = { args = vim.deepcopy(argv), asynchronous = callback ~= nil }
  elseif argv[1] == 'gh' and callback then
    active = active + 1; peak = math.max(peak, active)
    local done = callback
    callback = function(result) active = active - 1; done(result) end
  end
  return system(argv, opts, callback)
end
local function count(arg, since)
  local n = 0
  for i = (since or 0) + 1, #git_calls do
    if vim.tbl_contains(git_calls[i].args, arg) then n = n + 1 end
  end
  return n
end
f.delay = 40
ui.buf = assert(view.open({ root = f.root, url = f.pr.url }))
local publications = 0
vim.api.nvim_buf_attach(ui.buf, false, { on_lines = function(_, buf)
  publications = publications + 1
  assert(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]:match('^Repo:'), 'Published a partial PR layout')
end })
ui.loaded()
assert(peak >= 4, 'Review, viewer, public comments and thread state did not overlap')
assert(publications == 1, 'Initial layout changed while loading')
assert(count('fetch') == 1 and #view.model(ui.buf).threads == 3)
-- An expanded patch is immutable; fresh comments/metadata must not rebuild it.
ui.key('o', ui.row('file name.txt'))
ui.wait(function() return vim.tbl_contains(vim.api.nvim_buf_get_lines(ui.buf, 0, -1, false), '+TWO') end)
local previous = view.model(ui.buf)
local entry
for _, item in ipairs(previous.entries) do if item.path == 'file name.txt' then entry = item end end
assert(entry.patch)
local start = #git_calls
f.pr.title = 'Fresh title'
f.comments[1][#f.comments[1] + 1] = { id = 999, path = 'added.txt', side = 'RIGHT', line = 1,
  body = 'New comment', user = { login = 'reviewer' } }
ui.refresh()
local current = view.model(ui.buf)
assert(current.pr.title == 'Fresh title' and #current.threads == 4, 'Cached Git data hid fresh API state')
assert(current.entries ~= previous.entries)
local found
for _, item in ipairs(current.entries) do if item.path == entry.path then found = item end end
assert(found ~= entry and found.patch == entry.patch, 'Refresh discarded the immutable patch cache')
assert(count('fetch', start) == 0 and count('diff', start) == 0 and count('log', start) == 0,
  'Unchanged revisions repeated Git network/diff work')
-- Changed head fetches and rebuilds only the expanded patch, asynchronously.
vim.fn.writefile({ 'one', 'TWO', 'THREE', 'four' }, f.root .. '/file name.txt')
f.git({ 'add', 'file name.txt' }); f.git({ 'commit', '-qm', 'new head' })
f.pr.headRefOid = f.git({ 'rev-parse', 'HEAD' })
f.git({ 'update-ref', 'refs/pull/7/head', f.pr.headRefOid })
start = #git_calls
ui.refresh()
assert(view.model(ui.buf).hash == f.pr.headRefOid and ui.row('+THREE'))
assert(count('fetch', start) == 1 and count('--binary', start) == 1)
for i = start + 1, #git_calls do
  if vim.tbl_contains(git_calls[i].args, 'diff') then
    assert(git_calls[i].asynchronous, 'Rendering the refreshed patch blocked the UI')
  end
end
-- A changed base ref also invalidates the fetch shortcut.
f.git({ 'checkout', '-q', 'main' })
f.git({ 'commit', '--allow-empty', '-qm', 'base advanced again' })
f.pr.baseRefOid = f.git({ 'rev-parse', 'HEAD' })
f.git({ 'checkout', '-q', 'topic' })
start = #git_calls; ui.refresh()
assert(count('fetch', start) == 1 and view.model(ui.buf).pr.baseRefOid == f.pr.baseRefOid)
-- Closing and reopening retains only private refs, not mutable API responses.
vim.api.nvim_buf_delete(ui.buf, { force = true })
start = #git_calls; ui.open()
assert(count('fetch', start) == 0 and count('--name-status', start) == 1)
vim.api.nvim_buf_delete(ui.buf, { force = true })
f.cleanup()
print('PASS: concurrent API reads, single initial layout, verified ref reuse, fresh API state, cached diffs and asynchronous revision changes')
