-- Shared item access: display labels are never filesystem identities.
local M = {}
local api = vim.api
local git = require('plugins.harpoon_git')
local function absolute(item)
  if item.value:sub(1, 1) == '/' then return item.value end
  return vim.fs.normalize((item.context.root or vim.fn.getcwd()) .. '/' .. item.value)
end
M.path = absolute
function M.create(config, name, quiet)
  local pos = api.nvim_win_get_cursor(0)
  local supplied = name ~= nil
  if not name then
    local nav = git.capture(0, pos, not quiet)
    if nav then return { value = 'harpoon-git:' .. git.identity(nav), context = { git = nav, row = pos[1], col = pos[2] } } end
    name = api.nvim_buf_get_name(0)
    if name == '' or vim.bo.buftype ~= '' or name:match('^%a[%w+.-]*://') then
      if not quiet then vim.notify('This buffer has no persistent Harpoon target', vim.log.levels.INFO) end
      return nil
    end
  end
  -- New/edited file rows in the editable menu retain path:row:col support.
  if supplied and ((name:find(' · ', 1, true) and not name:match(':%d+:%d+$')) or name:match('^harpoon%-git:')) then
    vim.notify('Git pin labels cannot be edited; remove and pin the target again', vim.log.levels.INFO); return nil
  end
  local path, row, col
  if supplied then path, row, col = name:match('^(.*):(%d+):(%d+)$') end
  if path then name, pos = path, { tonumber(row), tonumber(col) } end
  local root = config.get_root_dir()
  local abs = vim.fn.fnamemodify(name, ':p')
  local prefix = root:gsub('/+$', '') .. '/'
  local value = abs:sub(1, #prefix) == prefix and abs:sub(#prefix + 1) or abs
  return { value = value, context = { row = pos[1], col = pos[2], root = root } }
end
function M.same_surface(a, b)
  if not a or not b then return false end
  local x, y = a.context.git, b.context.git
  if x or y then
    if not x or not y then return false end
    for _, field in ipairs({ 'root', 'view', 'revision', 'object', 'parent', 'filter', 'args', 'line_history', 'backend', 'flog_opts' }) do
      if not vim.deep_equal(x[field], y[field]) then return false end
    end
    if x.view == 'object' or x.view == 'blame' then return x.path == y.path end
    return true
  end
  return absolute(a) == absolute(b)
end
function M.menu()
  local harpoon = require('harpoon')
  local list = harpoon:list('multiple')
  if not harpoon.ui.win_id then
    local ok, source = pcall(M.create, list.config, nil, true)
    M.source = ok and source or nil
  end
  harpoon.ui:toggle_quick_menu(list)
end
function M.equals(a, b)
  if not a or not b then return a == b end
  if a.context.git or b.context.git then
    return a.context.git ~= nil and b.context.git ~= nil and git.identity(a.context.git) == git.identity(b.context.git)
  end
  return absolute(a) == absolute(b) and a.context.row == b.context.row
end
function M.display(item)
  if item.context.git then return git.label(item.context.git) end
  return item.value .. ':' .. (item.context.row or 1) .. ':' .. (item.context.col or 0)
end
function M.select(item, _, options)
  if not item then return end
  local ok, err = pcall(function()
    if options and options.tabedit then vim.cmd('tabnew')
    elseif options and options.vsplit then vim.cmd('vsplit')
    elseif options and options.split then vim.cmd('split') end
    if item.context.git then return git.open(item.context.git) end
    vim.cmd('edit ' .. vim.fn.fnameescape(absolute(item)))
    git.position(api.nvim_get_current_buf(), item.context.row, item.context.col)
  end)
  if not ok then vim.notify('Harpoon: ' .. tostring(err), vim.log.levels.WARN) end
end
function M.menu_item(buf, row)
  local harpoon = require('harpoon')
  local list = harpoon.ui.active_list
  if not list then return nil end
  local text = api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
  -- Resolve by label so preview follows unsaved menu reordering/deletions too.
  for index = 1, list:length() do
    local item = list:get(index)
    if item and M.display(item) == text then return item end
  end
  if text and text ~= '' and not text:find(' · ', 1, true) then return M.create(list.config, text) end
end
function M.matches(item, buf)
  if item.context.git then
    local ok, nav = pcall(git.capture, buf, { item.context.row or 1, item.context.col or 0 })
    if not ok or not nav then return false end
    local target = item.context.git
    if target.view == 'object' or target.view == 'blame' then
      nav.row = target.row
    end
    return git.identity(nav) == git.identity(target)
  end
  return api.nvim_buf_get_name(buf) == absolute(item)
end
function M.preview(item)
  if item.context.git then return git.preview(item.context.git) end
  local path = absolute(item)
  local lines
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_get_name(buf) == path and api.nvim_buf_is_loaded(buf) then
      lines = api.nvim_buf_get_lines(buf, 0, -1, false); break
    end
  end
  lines = lines or vim.fn.readfile(path)
  return lines, item.context.row or 1, item.context.col or 0, vim.filetype.match({ filename = path })
end
function M.toggle()
  local list = require('harpoon'):list('multiple')
  local ok, item = pcall(M.create, list.config)
  if not ok then vim.notify('Harpoon: ' .. tostring(item), vim.log.levels.WARN); return end
  if not item then return end
  for index = 1, list:length() do
    if M.equals(item, list:get(index)) then list:remove(item); return end
  end
  list:prepend(item)
end
return M
