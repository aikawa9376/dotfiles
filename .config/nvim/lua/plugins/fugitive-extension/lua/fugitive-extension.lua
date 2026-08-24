local M = {}

function M.setup()
  local group = vim.api.nvim_create_augroup('fugitive_custom', { clear = true })
  local nowrap_filetypes = {
    git = true,
    fugitive = true,
    fugitivestatus = true,
    fugitiveblame = true,
    fugitivebranch = true,
    fugitivelog = true,
    fugitivereflog = true,
    fugitivestash = true,
    fugitiveworktree = true,
    fugitiveactionmenu = true,
    gitrebase = true,
    gitcommit = true,
  }

  local function uses_nowrap(buf)
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then return false end
    if nowrap_filetypes[vim.bo[buf].filetype] then return true end
    local name = vim.api.nvim_buf_get_name(buf)
    return name:match('^fugitive://') ~= nil
      or name:match('^git%-diff://') ~= nil
      or name:match('^git%-range%-diff://') ~= nil
  end

  local function set_nowrap(win, buf)
    local target_win = win
    if not target_win
      or not vim.api.nvim_win_is_valid(target_win)
      or (buf and vim.api.nvim_win_get_buf(target_win) ~= buf)
    then
      target_win = buf and vim.fn.bufwinid(buf) or -1
    end
    if target_win ~= -1 and vim.api.nvim_win_is_valid(target_win) then
      vim.api.nvim_set_option_value('wrap', false, { win = target_win })
    end
  end

  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = vim.tbl_keys(nowrap_filetypes),
    callback = function(ev)
      set_nowrap(vim.api.nvim_get_current_win(), ev.buf)
    end,
  })

  vim.api.nvim_create_autocmd('BufWinEnter', {
    group = group,
    pattern = '*',
    callback = function(ev)
      if uses_nowrap(ev.buf) then set_nowrap(vim.api.nvim_get_current_win(), ev.buf) end
    end,
  })

  require('features.status').setup(group)
  require('features.blame').setup(group)
  require('features.commit').setup(group)
  require('features.blob').setup(group)
  require('features.stash').setup(group)
  require('features.branch').setup(group)
  require('features.log').setup(group)
  require('features.reflog').setup(group)
  require('features.worktree').setup(group)
  require('features.commands').setup()
end

return M
