local M = {}
function M.select(backend)
  local function set(value)
    if not value then return end
    assert(value == 'native' or value == 'flog', 'Graph backend must be native or flog')
    vim.g.git_graph_backend = value
    vim.notify('Git graph: ' .. value)
  end
  if backend and backend ~= '' then set(backend)
  else vim.ui.select({ 'flog', 'native' }, { prompt = 'Git graph backend' }, set) end
end
function M.open(revision, backend)
  backend = backend or vim.g.git_graph_backend or 'flog'
  assert(backend == 'native' or backend == 'flog', 'Graph backend must be native or flog')
  if backend == 'flog' then return require('git.flog').open(revision) end
  local objects, utils = require('git.objects'), require('git.utils')
  local root = objects.context()
  local args = { 'log', '--graph', '--decorate', '--format=%h %s %d', '-2000' }
  vim.list_extend(args, revision and { revision, '--' } or { '--all' })
  local text = objects.run(root, args)
  local origin = vim.api.nvim_get_current_win()
  vim.cmd('vertical rightbelow 60new')
  local b = vim.api.nvim_get_current_buf()
  utils.set_buf_work_tree(b, root)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, vim.split(text:gsub('\n$', ''), '\n'))
  vim.bo[b].buftype, vim.bo[b].bufhidden, vim.bo[b].filetype = 'nofile', 'wipe', 'git'
  vim.bo[b].modifiable = false
  vim.keymap.set('n', '<CR>', function()
    local hash = vim.api.nvim_get_current_line():match('[|%s*/\\_-]*(%x%x%x%x%x%x%x+) ')
    if not hash then return end
    if vim.api.nvim_win_is_valid(origin) then vim.api.nvim_set_current_win(origin) end
    require('git.features.commit').open({ work_tree = root, revision = hash })
  end, { buffer = b })
  vim.keymap.set('n', 'q', '<cmd>close<CR>', { buffer = b })
  return b
end
return M
