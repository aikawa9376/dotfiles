local M = {}

function M.setup()
  local group = vim.api.nvim_create_augroup('fugitive_custom', { clear = true })

  local function set_nowrap(win, buf)
    local target_win = win
    if not target_win or not vim.api.nvim_win_is_valid(target_win) then
      target_win = buf and vim.fn.bufwinid(buf) or -1
    end
    if target_win ~= -1 and vim.api.nvim_win_is_valid(target_win) then
      vim.api.nvim_set_option_value('wrap', false, { win = target_win })
    end
  end

  vim.api.nvim_create_autocmd({ 'FileType', 'BufWinEnter' }, {
    group = group,
    pattern = { 'git', 'fugitive', 'fugitiveblame', 'fugitivebranch', 'gitrebase', 'gitcommit' },
    callback = function(ev)
      set_nowrap(ev.win, ev.buf)
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
