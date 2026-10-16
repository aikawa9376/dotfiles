-- Run with nvim --headless --clean -u NONE -l <this file>.
-- Set RAINBOW_TRIGGER=BufNewFile to check the new-file entry point separately.
local root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
local config = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(root)))
local data = vim.fn.stdpath('data')
vim.opt.rtp:prepend(config)
vim.opt.rtp:prepend(data .. '/site')
vim.opt.rtp:prepend(data .. '/lazy/nvim-treesitter/runtime')
vim.opt.rtp:prepend(data .. '/lazy/lazy.nvim')
local fixture = vim.fn.tempname()
vim.fn.mkdir(fixture, 'p')

local ok, err = xpcall(function()
  require('lazy').setup({
    { import = 'plugins.rainbow-delimiters' },
    { 'rainbow-delimiters-extension', dir = root },
  }, {
    root = data .. '/lazy',
    lockfile = fixture .. '/lazy-lock.json',
    state = fixture .. '/state.json',
    install = { missing = false },
    checker = { enabled = false },
    change_detection = { enabled = false },
    readme = { enabled = false },
    performance = { rtp = { reset = false } },
  })
  local specs = require('lazy.core.config').plugins
  assert(not specs['rainbow-delimiters-extension']._.loaded, 'extension eagerly loaded')
  assert(not specs['rainbow-delimiters.nvim']._.loaded, 'upstream eagerly loaded')
  assert(not package.loaded['rainbow-delimiters.setup'], 'setup eagerly required')
  assert(not package.loaded['rainbow_delimiters.strategy'], 'strategy eagerly required')

  local event = vim.env.RAINBOW_TRIGGER or 'BufReadPre'
  local path = fixture .. '/example.lua'
  local lines = { 'local value = { nested = { 1, 2 } }' }
  if event == 'BufReadPre' then vim.fn.writefile(lines, path) end
  vim.cmd('filetype on')
  vim.cmd.edit(path)
  if event == 'BufNewFile' then vim.api.nvim_buf_set_lines(0, 0, -1, false, lines) end
  local buf = vim.api.nvim_get_current_buf()
  assert(vim.bo[buf].filetype == 'lua', 'filetype detection failed')
  assert(specs['rainbow-delimiters-extension']._.loaded, 'extension did not load on ' .. event)
  assert(specs['rainbow-delimiters.nvim']._.loaded, 'dependency did not load')
  local lib = require('rainbow-delimiters.lib')
  assert(lib.buffers[buf], 'first FileType missed rainbow attachment')
  assert(lib.buffers[buf].strategy == require('rainbow_delimiters.strategy'), 'wrong strategy selected')
  assert(vim.g.rainbow_delimiters.highlight[1] == 'RainbowDelimiterBlue', 'colors lost')
  vim.treesitter.start(buf)
  vim.treesitter.get_parser(buf):parse(true)
  assert(vim.wait(1000, function()
    return #vim.api.nvim_buf_get_extmarks(buf, lib.nsids.lua, 0, -1, {}) > 0
  end, 5), 'no delimiter highlights')
  print('rainbow lazy loading: import stays unloaded until ' .. event .. ', first file highlighted')
end, debug.traceback)

vim.fn.delete(fixture, 'rf')
if not ok then error(err) end
vim.cmd('qa!')
