-- Hunk cycling for standalone patches and native diff windows.
local M = {}
local api = vim.api
local initialized, syncing, scheduled = false, false, false
local temporary = {}
local keys = { { ']]', 1 }, { '[[', -1 } }

function M.unified(direction, count)
  local found = 0
  for _ = 1, count or vim.v.count1 do
    found = vim.fn.search([[^\s*@@\+ -\d.* +\d.* @@\+]], direction > 0 and 'w' or 'bw')
    if found == 0 then return end
  end
  vim.cmd('silent! normal! zv')
end

function M.native(direction, count)
  if not vim.wo.diff then return end
  local motion = direction > 0 and ']c' or '[c'
  for _ = 1, count or vim.v.count1 do
    local view = vim.fn.winsaveview()
    local before = api.nvim_win_get_cursor(0)[1]
    vim.cmd('silent! keepjumps normal! ' .. motion)
    if api.nvim_win_get_cursor(0)[1] == before then
      api.nvim_win_set_cursor(0, { 1, 0 })
      local first_changed = vim.fn.diff_hlID(1, 1) ~= 0 or vim.fn.diff_filler(1) > 0
      if direction < 0 then
        -- Native motions select block starts, including deletion filler and
        -- multi-line changes. At most one start can occur per buffer line.
        vim.cmd('silent! keepjumps normal! ' .. api.nvim_buf_line_count(0) .. ']c')
      elseif not first_changed then
        vim.cmd('silent! keepjumps normal! ]c')
      end
      if api.nvim_win_get_cursor(0)[1] == 1 and not first_changed then
        vim.fn.winrestview(view)
        return
      end
    end
  end
  vim.cmd('silent! normal! zv')
end

function M.attach_unified(buf)
  for _, key in ipairs(keys) do
    vim.keymap.set('n', key[1], function()
      if vim.wo.diff then M.native(key[2]) else M.unified(key[2]) end
    end, { buffer = buf, silent = true, desc = key[2] > 0 and 'Next diff hunk (wrap)' or 'Previous diff hunk (wrap)' })
  end
end

local function local_map(buf, key)
  for _, map in ipairs(api.nvim_buf_get_keymap(buf, 'n')) do
    if map.lhs == key then return map end
  end
end
local function restore(buf)
  for key, saved in pairs(temporary[buf] or {}) do
    local current = api.nvim_buf_is_valid(buf) and local_map(buf, key)
    if current and current.callback == saved.callback then
      vim.keymap.del('n', key, { buffer = buf })
      if saved.original then
        local original, options = saved.original, {}
        for _, name in ipairs({ 'noremap', 'silent', 'expr', 'nowait', 'script' }) do options[name] = original[name] == 1 end
        options.desc, options.callback = original.desc, original.callback
        if options.expr then options.replace_keycodes = original.replace_keycodes ~= 0 end
        local rhs = (original.rhs or ''):gsub('<SID>', '<SNR>' .. original.sid .. '_')
        api.nvim_buf_set_keymap(buf, 'n', key, rhs, options)
      end
    end
  end
  temporary[buf] = nil
end
function M.sync()
  if syncing then return end
  syncing = true
  local ok, err = pcall(function()
    local wanted = {}
    for _, win in ipairs(api.nvim_list_wins()) do
      if vim.wo[win].diff then wanted[api.nvim_win_get_buf(win)] = true end
    end
    -- Keymaps belong to buffers, but diff mode belongs to windows. When the
    -- same buffer is entered outside diff, expose its ordinary mappings.
    local current = api.nvim_get_current_buf()
    wanted[current] = vim.wo.diff or nil
    for buf in pairs(temporary) do if not wanted[buf] then restore(buf) end end
    for buf in pairs(wanted) do
      temporary[buf] = temporary[buf] or {}
      for _, key in ipairs(keys) do
        local saved, map = temporary[buf][key[1]], local_map(buf, key[1])
        if not saved or not map or map.callback ~= saved.callback then
          local callback = function() M.native(key[2]) end
          temporary[buf][key[1]] = { original = map, callback = callback }
          vim.keymap.set('n', key[1], callback, { buffer = buf, silent = true,
            desc = key[2] > 0 and 'Next diff hunk (wrap)' or 'Previous diff hunk (wrap)' })
        end
      end
    end
  end)
  syncing = false
  if not ok then error(err) end
end
function M.setup()
  if initialized then return end
  initialized = true
  local group = api.nvim_create_augroup('GitDiffNavigation', { clear = true })
  local function schedule()
    if scheduled then return end
    scheduled = true
    vim.schedule(function() scheduled = false; M.sync() end)
  end
  api.nvim_create_autocmd('FileType', { group = group, pattern = { 'diff', 'gitpatchcollection' },
    callback = function(ev) M.attach_unified(ev.buf) end })
  api.nvim_create_autocmd({ 'WinEnter', 'BufEnter', 'BufWinEnter', 'TabEnter', 'DiffUpdated' },
    { group = group, callback = schedule })
  api.nvim_create_autocmd('OptionSet', { group = group, pattern = 'diff', callback = schedule })
  api.nvim_create_autocmd({ 'WinClosed', 'BufUnload' }, { group = group, callback = schedule })
  schedule()
end
return M
