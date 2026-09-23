-- Git's editor process waits for this editor's buffer to close.
local M = { pending = {} }
function M.open(path, token)
  M.pending[token] = true
  vim.schedule(function()
    local ok, err = pcall(function()
      vim.cmd('stopinsert')
      vim.cmd('botright split ' .. vim.fn.fnameescape(path))
      local buf = vim.api.nvim_get_current_buf()
      vim.bo[buf].bufhidden = 'wipe'
      if path:match('git%-rebase%-todo$') then vim.bo[buf].filetype = 'gitrebase'
      else vim.bo[buf].filetype = 'gitcommit' end
      vim.api.nvim_create_autocmd('BufUnload', { buffer = buf, once = true, callback = function() M.pending[token] = nil end })
    end)
    if not ok then M.pending[token] = 'error'; vim.notify(tostring(err), vim.log.levels.ERROR) end
  end)
end
function M.environment()
  local server = vim.v.servername
  if server == '' then server = vim.fn.serverstart() end
  local source = debug.getinfo(1, 'S').source:sub(2)
  local plugin = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
  local command = vim.fn.shellescape(vim.v.progpath) .. ' --headless --clean -l ' .. vim.fn.shellescape(plugin .. '/scripts/editor.lua')
  return { GIT_EDITOR = command, GIT_SEQUENCE_EDITOR = command, GIT_NVIM_SERVER = server, GIT_PAGER = 'cat' }
end
return M
