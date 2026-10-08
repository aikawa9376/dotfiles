-- Run from the plugin root: nvim --headless --clean -u NONE -l tests/operation_progress.lua
local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path

local progress = require('git.features.operation_progress')
local root = vim.fn.tempname()
local other = root .. '-other'
vim.fn.mkdir(root, 'p')
vim.fn.mkdir(other, 'p')

assert(progress.status() == '', 'idle global operation state was not empty')
local first_fetch = progress.start(root, 'fetch')
assert(progress.status(root):find('Fetching', 1, true), 'fetch state was not reported')
assert(progress.status(other) == '', 'operation leaked into another repository')

local second_fetch = progress.start(root .. '/', 'fetch')
assert(progress.status(root):find('×2', 1, true), 'concurrent operations were not counted')
local pull = progress.start(root, 'pull')
local status = progress.status(root)
assert(status:find('Fetching', 1, true) and status:find('Pulling', 1, true),
  'different operations were not shown together')
local other_fetch = progress.start(other, 'fetch')
assert(progress.status():find('Fetching ×3', 1, true)
  and progress.status():find('Pulling', 1, true), 'global state did not aggregate worktrees')
assert(progress.status(root):find('Fetching ×2', 1, true)
  and not progress.status(other):find('Pulling', 1, true), 'worktree filters lost isolation')

local captured_config
local prior_lualine = package.loaded.lualine
local prior_lazyagent = package.loaded.lazyagent
package.loaded.lualine = {
  setup = function(config) captured_config = config end,
  refresh = function() end,
}
package.loaded.lazyagent = { status = function() return '' end }
dofile(plugin .. '/../lualine.lua').config()
local function find_operation_component(section)
  for _, component in ipairs(section) do
    if type(component) == 'table' and type(component[1]) == 'function'
      and component.color and component.color.fg == '#c678dd'
    then
      return component
    end
  end
end
local active_component = assert(find_operation_component(captured_config.sections.lualine_c),
  'active Lualine Git operation component was not placed with the diff component')
assert(not find_operation_component(captured_config.sections.lualine_x),
  'Git operation component remained in the right-side section')
local inactive_component = assert(find_operation_component(captured_config.inactive_sections.lualine_a),
  'inactive Git operation component was not placed beside the filename')
local bufnr = vim.api.nvim_get_current_buf()
vim.bo[bufnr].filetype = 'gitstatus'
vim.b[bufnr].git_work_tree = root
assert(active_component.cond() and active_component[1]():find('Fetching', 1, true),
  'Lualine did not show operation state in a Git buffer')
vim.bo[bufnr].filetype = 'lua'
vim.b[bufnr].git_work_tree = nil
vim.api.nvim_buf_set_name(bufnr, root .. '/file.lua')
assert(active_component.cond() and active_component[1]():find('Fetching ×3', 1, true),
  'Lualine hid background Git operations in a normal file buffer')
local other_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(other_buf, other .. '/file.lua')
vim.api.nvim_set_current_buf(other_buf)
assert(active_component.cond() and active_component[1]():find('Pulling', 1, true),
  'Lualine hid operations after switching to another repository')
local scratch = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(scratch)
assert(active_component.cond() and inactive_component.cond()
  and inactive_component[1]():find('Fetching ×3', 1, true),
  'Lualine hid background operations in an unnamed scratch buffer')
package.loaded['git.features.operation_progress'] = nil
assert(not active_component.cond(), 'Lualine did not handle an unloaded progress module')
package.loaded['git.features.operation_progress'] = progress

first_fetch()
first_fetch()
assert(progress.status(root):find('Fetching', 1, true)
  and not progress.status(root):find('×2', 1, true), 'finish callback was not idempotent')
second_fetch()
assert(progress.status(root):find('Pulling', 1, true) and not progress.status(root):find('Fetching', 1, true),
  'fetch completion cleared the wrong operation')
pull()
assert(progress.status(root) == '', 'completed operation remained active')
assert(active_component.cond() and active_component[1]():find('Fetching', 1, true)
  and not active_component[1]():find('×', 1, true), 'finishing one worktree hid another active operation')
other_fetch()
assert(progress.status() == '' and not active_component.cond() and not inactive_component.cond(),
  'Lualine still showed operation state after all jobs completed')

vim.api.nvim_set_current_buf(bufnr)
vim.api.nvim_buf_delete(other_buf, { force = true })
vim.api.nvim_buf_delete(scratch, { force = true })
package.loaded.lualine = prior_lualine
package.loaded.lazyagent = prior_lazyagent

vim.fn.delete(root, 'rf')
vim.fn.delete(other, 'rf')
print('PASS: worktree isolation, global operation counts, buffer-independent Lualine display, and completion')
