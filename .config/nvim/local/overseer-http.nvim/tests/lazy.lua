-- nvim --headless --clean -u NONE -l tests/lazy.lua
local source = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
local config = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source))))
local plugins = vim.fn.stdpath('data') .. '/lazy'
vim.opt.rtp:prepend(config)
vim.opt.rtp:prepend(plugins .. '/lazy.nvim')
vim.cmd('filetype plugin on')
vim.keymap.set('n', '<CR>', 'i<CR><Esc>==')
local fixture = vim.fn.tempname()
vim.fn.mkdir(fixture, 'p')
local ok, err = xpcall(function()
  require('lazy').setup({ dofile(config .. '/lua/plugins/overseer.lua') }, {
    root = plugins,
    lockfile = fixture .. '/lazy-lock.json',
    state = fixture .. '/state.json',
    install = { missing = false },
    checker = { enabled = false },
    change_detection = { enabled = false },
    readme = { enabled = false },
    performance = { rtp = { reset = false } },
  })
  local specs = require('lazy.core.config').plugins
  assert(not specs['overseer.nvim']._.loaded)
  assert(vim.fn.exists(':OverseerHttpSelect') == 2)
  local file = fixture .. '/api.http'
  vim.fn.writefile({ '### Health', 'GET https://example.test/health' }, file)
  vim.cmd.edit(vim.fn.fnameescape(file))
  vim.bo.filetype = 'http'
  local http_map = vim.fn.maparg('<CR>', 'n', false, true)
  assert(http_map.buffer == 1 and http_map.rhs:find('OverseerHttpRun', 1, true))
  assert(vim.fn.maparg('<leader>Rs', 'n', false, true).buffer == 1)
  assert(vim.b.current_syntax == 'overseer_http')
  assert(vim.fn.synIDattr(vim.fn.synID(2, 2, 1), 'name') == 'OverseerHttpMethod')
  local selected
  vim.ui.select = function(items) selected = items end
  vim.cmd('OverseerHttpSelect')
  assert(specs['overseer.nvim']._.loaded)
  assert(specs['overseer-http.nvim']._.loaded)
  assert(#selected == 1 and selected[1].name == 'Health')
  local other = fixture .. '/plain.txt'
  vim.fn.writefile({ 'plain' }, other)
  vim.cmd.edit(vim.fn.fnameescape(other))
  assert(vim.fn.maparg('<CR>', 'n', false, true).buffer == 0)
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.bo[scratch].buftype = 'nofile'
  vim.api.nvim_win_set_buf(0, scratch)
  vim.bo[scratch].filetype = 'http'
  assert(vim.fn.maparg('<CR>', 'n', false, true).buffer == 0)
  assert(vim.b.current_syntax == 'overseer_http')
  local rest = fixture .. '/api.rest'
  vim.fn.writefile({
    'POST https://example.test',
    'Content-Type: application/json',
    '',
    '{"name":"x"}',
  }, rest)
  vim.cmd.edit(vim.fn.fnameescape(rest))
  vim.bo.filetype = 'rest'
  assert(vim.fn.maparg('<CR>', 'n', false, true).buffer == 1)
  assert(vim.b.current_syntax == 'overseer_http')
  assert(vim.fn.synIDattr(vim.fn.synID(4, 3, 1), 'name') == 'jsonKeyword')
  print('PASS: lazy command loads Overseer and overseer-http')
end, debug.traceback)
vim.fn.delete(fixture, 'rf')
if not ok then error(err) end
vim.cmd('qa!')
