local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
local obsidian = vim.fs.dirname(plugin) .. '/obsidian-extension'
package.path = plugin .. '/lua/?.lua;' .. obsidian .. '/lua/?.lua;' .. package.path
local vault = vim.fn.tempname()
vim.fn.mkdir(vault .. '/notes/projects/captured/feature', 'p')
vim.fn.writefile({ '---', 'project: captured', 'branch: feature/test', '---', '# Branch note' },
  vault .. '/notes/projects/captured/feature/test.md')
vim.fn.writefile({ '---', 'project: captured', '---', '# Project note' }, vault .. '/notes/project.md')
vim.fn.writefile({ '# Unrelated' }, vault .. '/notes/unrelated.md')
local note_path = vault .. '/notes/projects/captured/feature/test.md'
local modified = os.time({ year = 2025, month = 4, day = 12, hour = 12 })
assert(vim.uv.fs_utime(note_path, modified, modified))
package.loaded['obsidian'] = { get_client = function() return { dir = vault } end }
local definition = require('git.integrations.obsidian').module({ before = 'unstaged', limit = 1 })
assert(definition.before == 'unstaged' and not definition.after)
local items, failure
definition.load({ root = '/captured', branch = 'feature/test', paths = { 'unrelated.md' } }, function(result, err)
  items, failure = result, err
end)
assert(vim.wait(5000, function() return items or failure end, 10), 'Shelf query did not finish')
assert(not failure and #items == 1 and items[1].text == 'Branch note')
assert(items[1].id == items[1].path and vim.tbl_contains(items[1].reasons, 'branch'))
assert(items[1].detail == '2025-04-12', 'Shelf date must come from the indexed note modification time')
assert(items[1].score == 350 and vim.tbl_contains(items[1].reasons, 'branch_note'), 'Adapter should share the canonical branch-note boost')
definition.open({}, items[1])
assert(vim.api.nvim_buf_get_name(0) == items[1].path, 'Open did not use the canonical note path')
assert(not pcall(definition.open, {}, { path = vault .. '/missing.md' }), 'Deleted notes opened an empty buffer')
package.loaded['obsidian'] = { get_client = function() error('No client') end }
failure = nil
definition.load({ root = '/captured', branch = 'main' }, function(result, err) assert(not result); failure = err end)
assert(failure and failure:find('vault'), 'Unavailable workspaces did not finish with an error')
vim.cmd('tabclose')
vim.fn.delete(vault, 'rf')
print('PASS: Obsidian shelf reuses captured Git context, shared ranking/workspace config, stable note identities and opens canonical files')
