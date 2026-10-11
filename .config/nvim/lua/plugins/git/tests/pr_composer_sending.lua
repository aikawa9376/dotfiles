local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.pr_fixture').new()
local composer, github = require('git.features.pr_composer'), require('git.features.github')
local submits, deletes = 0, 0
local ctx = { root = f.root, host = 'ghe.example.test', repo = 'org/repo', number = 7, url = f.pr.url }
local function title(win)
  return table.concat(vim.tbl_map(function(chunk) return chunk[1] end, vim.api.nvim_win_get_config(win).title))
end
local function key(key)
  assert(pcall(vim.fn.maparg(key, 'n', false, true).callback), 'Repeated save/delete raised an exception')
end
f.delay = 300; f.comment_error = true
local buf = composer.open({ ctx = ctx, title = 'PR reply', body = 'Unchanged draft',
  prefix = { 'PR #7 · file name.txt:2 (RIGHT)', '' }, history = { { body = 'Earlier conversation', user = { login = 'author' } } },
  submit = function(resolved, body)
    submits = submits + 1
    return github.api(resolved, 'repos/org/repo/issues/7/comments', { body = body })
  end,
  delete = function() deletes = deletes + 1 end, delete_prompt = 'Delete this draft?',
})
local win, context = vim.api.nvim_get_current_win(), vim.b[buf].git_pr_context
local idle_title = title(win)
assert(idle_title:find('<C-s>/:w send', 1, true) and idle_title:find('gX delete', 1, true))
local lines = vim.api.nvim_buf_get_lines(context, 0, -1, false)
assert(lines[1] == 'PR #7 · file name.txt:2 (RIGHT)' and lines[#lines] == 'Earlier conversation')
assert(not table.concat(lines, '\n'):find('<C-s>', 1, true))
vim.v.errmsg = ''
-- One actual Insert-mode Ctrl-s starts exactly one request.
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('i<C-s>', true, false, true), 'xt', false)
assert(submits == 1 and not vim.bo[buf].modifiable and title(win):find('◐', 1, true))
local first_title = title(win)
assert(first_title:sub(1, #idle_title) == idle_title, 'Spinner replaced the title / shortcuts')
assert(vim.fn.strdisplaywidth(first_title) == vim.api.nvim_win_get_width(win), 'Spinner is not at the right edge')
-- Repeat from both panels and :w while the first write is still in flight.
key('<C-s>'); assert(pcall(vim.cmd, 'write')); key('gX'); key('<Tab>'); key('<C-s>'); key('<Tab>')
assert(submits == 1 and deletes == 0 and vim.v.errmsg == '' and not vim.bo[buf].modifiable)
assert(vim.wait(250, function() return title(win) ~= first_title end, 10), 'Loading indicator did not rotate')
assert(vim.wait(5000, function() return vim.bo[buf].modifiable end, 10))
assert(title(win) == idle_title and vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == 'Unchanged draft')
assert(f.notifications[#f.notifications]:find('server rejected write', 1, true), 'Real send failure was suppressed')
-- After failure, one retry is allowed; repeated saves still do not duplicate it.
f.comment_error = false
key('<C-s>'); key('<C-s>'); assert(pcall(vim.cmd, 'write'))
assert(submits == 2 and not vim.bo[buf].modifiable)
assert(vim.wait(5000, function() return not vim.api.nvim_buf_is_valid(buf) end, 10))
assert(#f.discussion == 1 and not vim.api.nvim_buf_is_valid(context) and vim.v.errmsg == '')
assert(vim.wait(150, function() return false end, 10) == false) -- queued spinner ticks must expire harmlessly.
f.cleanup()
print('PASS: Insert Ctrl-s, repeated saves/history/delete, right-edge spinner, failure restoration and one successful retry')
