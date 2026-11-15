local M = {}
local state

function M.active() return state ~= nil end

function M.focus_status(root)
  if not state or state.restoring or root ~= state.root then return end
  if vim.api.nvim_win_is_valid(state.win) and vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_set_current_win(state.win)
    vim.api.nvim_win_set_buf(state.win, state.buf)
    return state.buf
  end
end

local function remember_home(buf)
  state.buf, state.win, state.tab = buf, vim.api.nvim_get_current_win(), vim.api.nvim_get_current_tabpage()
  vim.api.nvim_tabpage_set_var(state.tab, 'git_status_work_tree', state.root)
  vim.keymap.set('n', '<C-c>', M.quit, { buffer = buf, silent = true, desc = 'Exit Git application' })
end

local function restore_home()
  if M.focus_status(state.root) then return end
  state.restoring = true
  vim.cmd('tabnew')
  remember_home(assert(require('git.features.status').open({ work_tree = state.root })))
  state.restoring = false
end

function M.quit()
  if not state or state.leaving or state.quitting then return false end
  state.quitting = true
  local ok, err = pcall(vim.cmd, 'confirm qall')
  state.quitting = false
  -- A cancelled quit must leave a usable home even if :q/:bdelete already
  -- removed its original window or buffer. Never force-discard editor drafts.
  restore_home()
  if not ok then vim.notify(tostring(err), vim.log.levels.WARN) end
  return false
end

local function schedule_quit()
  if state.leaving or state.quitting or state.quit_scheduled then return end
  state.quit_scheduled = true
  vim.schedule(function()
    state.quit_scheduled = false
    M.quit()
  end)
end

function M.close_view()
  if not state then return false end
  local tab = vim.api.nvim_get_current_tabpage()
  if tab == state.tab then return require('utilities').smart_close() end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if vim.bo[vim.api.nvim_win_get_buf(win)].modified then
      vim.notify('Save changes before closing this tab', vim.log.levels.WARN)
      return false
    end
  end
  vim.cmd('tabclose')
  restore_home()
  return true
end

function M.file_window(status_win)
  if not state then return end
  vim.api.nvim_set_current_win(status_win)
  vim.cmd('tabnew')
  state.children[vim.api.nvim_get_current_tabpage()] = true
  require('utilities').remember_smart_close({ source_win = status_win, created = true })
  return vim.api.nvim_get_current_win(), true
end

local function setup_file_view(buf)
  local tab = vim.api.nvim_get_current_tabpage()
  if not state.children[tab] then return end
  local ft = vim.bo[buf].filetype
  if (vim.bo[buf].buftype == '' or vim.b[buf].git_object) and ft ~= 'gitcommit' and ft ~= 'gitrebase' then
    vim.wo.number = true
    vim.wo.relativenumber = false
    vim.keymap.set('n', 'q', M.close_view, { buffer = buf, silent = true, nowait = true, desc = 'Return to Git status' })
  end
  -- Native panel closing can restore the empty buffer that preceded Gedit.
  -- Once a managed inspection tab is empty, it has served its purpose.
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    local candidate = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_buf_get_name(candidate) ~= '' or vim.bo[candidate].modified then return end
  end
  M.close_view()
end

local function protect_home(buf)
  if vim.api.nvim_get_current_win() ~= state.win or buf == state.buf then return end
  local ft = vim.bo[buf].filetype
  if vim.bo[buf].buftype ~= '' or vim.api.nvim_buf_get_name(buf) == ''
    or ft == 'gitcommit' or ft == 'gitrebase' then return end
  vim.api.nvim_win_set_buf(state.win, state.buf)
  M.file_window(state.win)
  vim.api.nvim_win_set_buf(0, buf)
end

function M.statusline()
  if not state then return '' end
  local root = vim.fs.basename(state.root):gsub('%%', '%%%%')
  local loading = require('git.features.loading').statusline():gsub('%%', '%%%%')
  local name = vim.bo.filetype == 'gitstatus' and 'Status' or '%t'
  return ' Git │ ' .. root .. ' │ %<' .. name .. ' %m%=' .. loading .. '  %l:%c '
end

function M.start(root)
  assert(not state, 'Git application is already running')
  state = { root = root, children = {}, restoring = true }
  local buf = assert(require('git.features.status').open({ work_tree = root }), 'Could not open Git status')
  remember_home(buf)
  state.restoring = false
  vim.o.showtabline = 0
  vim.o.statusline = "%!v:lua.require'git.features.application'.statusline()"
  require('utilities').register_smart_close('git-application', function(ctx)
    if ctx.buf == state.buf and ctx.win == state.win then return { close = M.quit } end
  end)
  local group = vim.api.nvim_create_augroup('GitApplication', { clear = true })
  vim.api.nvim_create_autocmd('VimLeavePre', { group = group, callback = function() state.leaving = true end })
  vim.api.nvim_create_autocmd('WinClosed', { group = group, callback = function(ev)
    if tonumber(ev.match) == state.win then schedule_quit() end
  end })
  vim.api.nvim_create_autocmd({ 'BufDelete', 'BufWipeout' }, { group = group, callback = function(ev)
    if ev.buf == state.buf then schedule_quit() end
  end })
  vim.api.nvim_create_autocmd('TabClosed', { group = group, callback = function()
    if state.leaving or state.quitting then return end
    for tab in pairs(state.children) do
      if not vim.api.nvim_tabpage_is_valid(tab) then state.children[tab] = nil end
    end
    local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    vim.schedule(function()
      if state.leaving or state.quitting or state.quit_scheduled then return end
      if vim.api.nvim_get_current_win() == win and vim.api.nvim_get_current_buf() == buf
        and vim.api.nvim_win_is_valid(state.win) then M.focus_status(state.root) end
    end)
  end })
  vim.api.nvim_create_autocmd('BufEnter', { group = group, callback = function(ev)
    vim.schedule(function()
      if not state.leaving and vim.api.nvim_buf_is_valid(ev.buf) and vim.api.nvim_get_current_buf() == ev.buf then
        protect_home(ev.buf)
        setup_file_view(ev.buf)
      end
    end)
  end })
  vim.api.nvim_exec_autocmds('User', { pattern = 'GitApplicationReady', modeline = false })
  return buf
end

return M
