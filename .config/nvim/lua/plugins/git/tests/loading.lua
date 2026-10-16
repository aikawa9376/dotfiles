local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
local loading = require('git.features.loading')
local buf = vim.api.nvim_get_current_buf()
local function wait(fn) assert(vim.wait(2000, fn, 10), 'Loading state did not settle') end
local function pause(ms) vim.wait(ms, function() return false end, 10) end

local fast = loading.begin(buf, 'fast')
fast(); fast()
pause(200)
assert(not loading.busy(buf) and loading.status(buf) == '', 'Fast tasks flashed a loading indicator')
local first, second = loading.begin(buf, 'repository'), loading.begin(buf, 'shelf')
wait(function() return loading.status(buf):find('Loading', 1, true) end)
first(); first()
assert(loading.busy(buf) and loading.status(buf) ~= '', 'One completion hid another active source')
local stale = loading.begin(buf, 'repository')
local current = loading.begin(buf, 'repository')
stale(); second()
assert(loading.busy(buf), 'Superseded completion finished a replacement task')
current()
assert(not loading.busy(buf) and loading.status(buf) ~= '', 'Completion skipped the quiet period')
pause(80)
local followup = loading.begin(buf, 'followup')
assert(loading.status(buf) ~= '', 'A nearby task caused a hide/show transition')
followup()
wait(function() return loading.status(buf) == '' end)

-- Data-ready and displayed are distinct. Out-of-order replies are projected in
-- configuration order, and only a committed projection completes their tokens.
local modules = require('git.features.status_modules')
local requests = {}
modules.setup({
  { id = 'first', title = 'First', before = 'header', load = function(_, done) requests.first = done end },
  { id = 'second', title = 'Second', before = 'header', load = function(_, done) requests.second = done end },
  { id = 'broken', title = 'Broken', load = function() error('failed to load') end },
})
modules.attach(buf, function() end)
modules.refresh(buf, { root = '/fixture', branch = 'main' })
wait(function() return requests.first and requests.second end)
requests.second({ { id = 'second', text = 'Second item' } })
pause(20)
requests.first({ { id = 'first', text = 'First item' } })
pause(20)
assert(loading.busy(buf), 'Receiving all responses finished before their display')
local lines, _, rows = modules.compose(buf, { 'Head: main', '' })
local text = table.concat(lines, '\n')
assert(text:find('First item') < text:find('Second item'), 'Completion order changed shelf order')
assert(text:find('Unavailable:') and not text:find('Loading'), 'Provider failures or placeholders were lost')
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
modules.commit(buf, rows)
assert(not loading.busy(buf), 'Committed projection retained loading tokens')
modules.cleanup(buf)
modules.setup({})
wait(function() return loading.status(buf) == '' end)

local config, refreshes = nil, 0
package.loaded.lualine = {
  setup = function(value) config = value end,
  refresh = function() refreshes = refreshes + 1 end,
}
package.loaded.lazyagent = { status = function() return '' end }
dofile(plugin .. '/../lualine.lua').config()
local finish = loading.begin(buf, 'display')
wait(function() return loading.statusline({}) ~= '' end)
local function component(section)
  for _, item in ipairs(section) do
    if type(item) == 'table' and type(item[1]) == 'function' then
      local ok, value = pcall(item[1])
      if ok and value == loading.status(buf) then return item end
    end
  end
end
local active = assert(component(config.sections.lualine_c), 'Missing active Lualine component')
local inactive = assert(component(config.inactive_sections.lualine_a), 'Missing inactive Lualine component')
assert(active.cond() and inactive.cond() and refreshes > 0)
local other = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(other)
assert(not active.cond() and loading.status(buf) ~= '', 'Loading leaked into another view')
vim.api.nvim_set_current_buf(buf)
finish()
wait(function() return not active.cond() end)
loading.begin(other, 'closed')
vim.api.nvim_buf_delete(other, { force = true })
pause(100)
assert(not loading.busy(other), 'Unloaded view retained its tasks')
loading.cleanup(buf)
local late = loading.begin(buf, 'late')
loading.cleanup(buf); late()
assert(not loading.busy(buf) and loading.status(buf) == '')
print('PASS: one stable loading lifetime, stale tokens, ordered projection, errors, Lualine and teardown')
