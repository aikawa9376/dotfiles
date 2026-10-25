local M = {}
local objects = require('git.objects')

function M.open(o, vertical)
  local root, path, source = objects.context()
  assert(path, 'No current file')
  local args = require('git.commands').argv(o.args)
  local after
  if args[1] == '++novertical' then vertical = false; table.remove(args, 1) end
  if args[1] and args[1]:sub(1, 1) == '+' then after = table.remove(args, 1):sub(2) end
  assert(#args <= 1, 'Expected one revision or object')
  local unmerged = objects.run(root, { 'ls-files', '-u', '--', path })
  local targets = {}
  local explicit = args[1] and args[1] ~= ':' and args[1] ~= '>:'
  if explicit then
    local _, object, _, kind = objects.resolve(args[1])
    if kind == 'object' and not object:find(':', 1, true) then object = object .. ':' .. path end
    targets[1] = object
  elseif o.bang then
    if unmerged ~= '' and (not source or source.stage == '1') then
      for _, stage in ipairs({ '2', '3' }) do
        if unmerged:find(' ' .. stage .. '\t', 1, true) then targets[#targets + 1] = ':' .. stage .. ':' .. path end
      end
    elseif source and source.revision then
      local parents = vim.split(vim.trim(objects.run(root, { 'rev-list', '--parents', '-n', '1', source.revision })), ' ', { plain = true })
      for i = 2, #parents do targets[#targets + 1] = parents[i] .. ':' .. path end
      if #targets == 0 then targets[1] = false end -- A root commit has an empty predecessor.
    else targets[1] = (source and 'HEAD' or ':0') .. ':' .. path end
  elseif source then targets[1] = root .. '/' .. path
  else targets[1] = (unmerged ~= '' and ':1' or ':0') .. ':' .. path end
  -- Validate every target before creating a window, including missing files in parents.
  local empty = {}
  for i, target in ipairs(targets) do
    if target == false then empty[i] = true
    elseif target:sub(1, 1) ~= '/' then
      local ok = pcall(objects.run, root, { 'rev-parse', '--verify', '--end-of-options', target })
      if not ok and source and (source.revision or source.stage == '0') and not explicit then empty[i] = true
      else assert(ok, 'Cannot resolve diff target: ' .. target) end
    end
  end
  local mods = o.smods or {}
  if mods.vertical then vertical = true elseif mods.horizontal then vertical = false end
  if vertical == nil then
    local diffopt = vim.o.diffopt
    local fit = vim.g.git_diffsplit_directional_fit
    if fit == nil then fit = vim.g.fugitive_diffsplit_directional_fit end
    vertical = diffopt:find('vertical', 1, true) ~= nil
      or (not diffopt:find('horizontal', 1, true)
        and fit ~= false and fit ~= 0
        and vim.api.nvim_win_get_width(0) > (#targets + 1) * ((vim.bo.textwidth > 0 and vim.bo.textwidth or 80) + 2))
  end
  local original, origin = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  if mods.tab and mods.tab >= 0 then vim.cmd('tab split'); original = vim.api.nvim_get_current_win() end
  local comparisons = {}
  for i, target in ipairs(targets) do
    vim.api.nvim_set_current_win(original)
    local side = (not o.bang and source and not explicit or i > 1) and 'rightbelow ' or 'leftabove '
    if mods.split and mods.split ~= '' then side = mods.split .. ' ' end
    local command = 'keepalt ' .. side .. (vertical and 'vsplit' or 'split')
    if empty[i] then
      vim.cmd(command)
      local b = vim.api.nvim_create_buf(false, true); vim.api.nvim_win_set_buf(0, b)
      vim.b[b].git_diff_missing = true
      vim.bo[b].bufhidden, vim.bo[b].modifiable = 'wipe', false
    else objects.open(target, command, root) end
    vim.cmd('diffthis')
    comparisons[#comparisons + 1] = { win = vim.api.nvim_get_current_win(), buf = vim.api.nvim_get_current_buf() }
  end
  vim.api.nvim_set_current_win(original); vim.cmd('diffthis')
  if #comparisons > 1 then
    for i, target in ipairs(comparisons) do
      vim.keymap.set('n', 'd' .. (i + 1) .. 'o', '<cmd>diffget ' .. target.buf .. '<bar>diffupdate<CR>', { buffer = origin, silent = true })
      vim.keymap.set('n', 'dp', '<cmd>diffput ' .. origin .. '<bar>diffupdate<CR>', { buffer = target.buf, silent = true })
    end
  end
  if not o.bang then vim.api.nvim_set_current_win(comparisons[#comparisons].win) end
  if after and after ~= '' then vim.cmd(after) end
end
return M
