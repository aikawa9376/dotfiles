local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.pr_fixture').new()
vim.o.columns, vim.o.lines = 150, 60
f.git({ 'config', 'branch.topic.pullRequestUrl', 'https://ghe.example.test/wrong/repo/pull/999' })
-- Keep Git and gh repo resolution real/asynchronous through the fixture, but
-- release associated-PR responses explicitly to exercise stale-result races.
local transport, requests = vim.system, {}
vim.system = function(argv, opts, callback)
  local hash
  if argv[1] == 'gh' and argv[2] == 'api' then
    for _, value in ipairs(argv) do hash = hash or value:match('^repos/org/repo/commits/(%x+)/pulls') end
  end
  if not hash then return transport(argv, opts, callback) end
  local request = { hash = hash, cwd = opts.cwd }
  requests[#requests + 1] = request
  function request.reply(items, err)
    callback({ code = err and 1 or 0, stdout = vim.json.encode(items or {}), stderr = err or '' })
  end
  return { kill = function() request.killed = true end }
end
local function wait(predicate, label) assert(vim.wait(4000, predicate, 10), label) end
vim.cmd('edit ' .. vim.fn.fnameescape(f.root .. '/file name.txt'))
local origin, code = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
vim.api.nvim_buf_set_lines(origin, 3, 4, false, { 'unsaved' })
local blame = require('git.features.blame')
blame.setup(vim.api.nvim_create_augroup('BlamePrPreviewTest', {}))
local buf = blame.open()
wait(function() return vim.fn.bufwinid(buf) ~= -1 end, 'blame open')
local panel = vim.fn.bufwinid(buf)
local function press(key)
  local mapping = vim.fn.maparg(key, 'n', false, true)
  assert(mapping.callback, key)()
end
local function move(win, row)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { row, 0 })
  vim.api.nvim_exec_autocmds('CursorMoved', { buffer = vim.api.nvim_win_get_buf(win) })
end
local function preview()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local config = vim.api.nvim_win_get_config(win)
    if config.zindex == 60 and config.relative ~= '' then
      local b = vim.api.nvim_win_get_buf(win)
      return { win = win, buf = b, config = config,
        text = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), '\n') }
    end
  end
end
local function loaded(value)
  wait(function() return preview() and preview().text:find(value, 1, true) end, value)
  return preview()
end
local function requested(count)
  wait(function() return #requests == count end, 'PR request ' .. count)
  return requests[count]
end
local function item(number, title, base)
  return { number = number, html_url = f.pr.url:gsub('/7$', '/' .. number), title = title or 'Related PR',
    state = 'open', head = { ref = 'topic' }, base = { ref = base or 'main' } }
end
local function fitted(popup)
  local content = vim.api.nvim_win_text_height(popup.win, { start_row = 0,
    end_row = vim.api.nvim_buf_line_count(popup.buf) - 1 }).all
  assert(popup.config.height == math.min(content, vim.api.nvim_win_get_height(code) - 4),
    'Preview height must follow actual wrapped content without reserved blank rows')
end
move(panel, 1); press('gk')
local initial = assert(preview())
assert(initial.text:sub(-4) == 'base' and not initial.text:find('Pull requests', 1, true))
assert(initial.config.width < math.min(80, vim.api.nvim_win_get_width(code) - 4), 'Initial message reserved PR width')
fitted(initial)
local first = requested(1)
assert(first.hash == f.base and first.cwd == f.root, 'PR lookup used HEAD instead of the blamed commit')
vim.cmd('cd /tmp')
first.reply({ item(7, 'Unicode PR ' .. string.rep('関連', 25)), item(8, 'Another base', 'release') })
local expanded = loaded('#7 [open]')
assert(expanded.win == initial.win and expanded.buf == initial.buf, 'Loading PRs replaced the preview window')
assert(expanded.text:find('#8 [open]', 1, true) and expanded.text:find('topic → release', 1, true))
assert(expanded.config.height > initial.config.height and expanded.config.width > initial.config.width)
assert(vim.api.nvim_get_current_win() == panel, 'Async PR display stole focus')
fitted(expanded)
-- Redraw/scroll must not temporarily shrink wrapped content, which would
-- generate another WinResized event and keep triggering layout work.
assert(expanded.config.height > vim.api.nvim_buf_line_count(expanded.buf), 'Fixture must exercise wrapping')
local set_config = vim.api.nvim_win_set_config
local resized = {}
vim.api.nvim_win_set_config = function(win, config)
  if win == expanded.win and config.height then resized[#resized + 1] = config.height end
  return set_config(win, config)
end
vim.api.nvim_exec_autocmds('WinScrolled', { pattern = tostring(panel) })
vim.wait(40, function() return false end, 10)
vim.api.nvim_win_set_config = set_config
assert(#resized > 0)
for _, height in ipairs(resized) do assert(height == expanded.config.height, 'Stable preview resized during layout') end
-- Same-commit movement reuses results and follows the new code-row anchor.
move(panel, 3)
wait(function() return preview().config.bufpos[1] == 2 end, 'same commit follows row')
assert(#requests == 1 and preview().text == expanded.text)
-- Both panes use attribution, canceling the superseded commit immediately.
move(code, 2)
local second = requested(2)
assert(second.hash == f.head)
local compact = preview()
assert(not compact.text:find('Pull requests', 1, true) and compact.config.width < expanded.config.width)
move(panel, 1); assert(second.killed, 'Cursor movement did not cancel the old lookup')
second.reply({ item(99, 'Stale result') })
loaded('#7 [open]')
assert(not preview().text:find('#99', 1, true))
-- Toggle off and switch to diff while loading: no late callback can reopen gk.
move(panel, 2); local third = requested(3)
press('gk'); assert(not preview() and third.killed)
third.reply({ item(99) })
vim.wait(40, function() return false end, 10); assert(not preview())
press('gk'); local fourth = requested(4)
press('<C-p>'); assert(fourth.killed and preview().text:find('diff --git', 1, true))
fourth.reply({ item(99) })
vim.wait(40, function() return false end, 10)
assert(not preview().text:find('Pull requests', 1, true)); press('<C-p>')
-- Failures and empty results arrive inline, and explicit R permits a fresh read.
press('gk'); local fifth = requested(5)
fifth.reply(nil, 'GitHub unavailable')
loaded('Could not load PR information: GitHub unavailable'); fitted(preview())
press('R'); local sixth = requested(6)
assert(not preview().text:find('Could not load', 1, true))
local before_empty = preview()
sixth.reply({})
local settled = false
vim.schedule(function() settled = true end)
wait(function() return settled end, 'empty PR lookup completed')
assert(preview().text == before_empty.text and preview().config.height == before_empty.config.height
  and preview().config.width == before_empty.config.width, 'No PRs must leave the message and size unchanged')
fitted(preview())
-- Unsaved attribution never queries GitHub or inherits another commit's PRs.
move(code, 4); loaded('Not committed yet')
assert(#requests == 6 and not preview().text:find('Pull requests', 1, true))
fitted(preview())
-- Closing the float directly cancels and disables follow mode as well.
move(panel, 1); local seventh = requested(7)
vim.api.nvim_win_close(preview().win, true)
assert(seventh.killed and not preview())
seventh.reply({ item(77) })
vim.api.nvim_exec_autocmds('WinScrolled', { pattern = tostring(panel) })
vim.wait(40, function() return false end, 10); assert(not preview())
-- Session teardown owns the remaining request and never recreates its buffers.
press('gk'); local eighth = requested(8)
local dying = preview()
press('q'); assert(eighth.killed and not vim.api.nvim_buf_is_valid(buf))
eighth.reply({ item(88) })
vim.wait(40, function() return false end, 10)
assert(not preview() and not vim.api.nvim_buf_is_valid(dying.buf))
assert(vim.api.nvim_get_current_win() == code and vim.bo[origin].modified)
f.cleanup()
print('PASS: blame PR attribution, deferred growth, wrapped sizing, cached following, stale reads, toggles and cleanup')
