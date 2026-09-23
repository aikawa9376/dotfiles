-- Flog's documented backend hooks, without loading Fugitive.
local M = {}
function M.setup()
  local utils = require('git.utils')
  _G.GitFlogIsGitBuf = function() return utils.get_work_tree({}) ~= nil end
  _G.GitFlogGitDir = function()
    local root = utils.get_work_tree({})
    return root and utils.get_git_dir(root) or ''
  end
  _G.GitFlogSetupBuffer = function(root) utils.set_buf_work_tree(vim.api.nvim_get_current_buf(), root) end
  _G.GitFlogComplete = function(...) return require('git.completion').git(...) end
  vim.cmd([[
    function! GitFlogIsGitBuf() abort
      return v:lua.GitFlogIsGitBuf()
    endfunction
    function! GitFlogGitDir() abort
      return v:lua.GitFlogGitDir()
    endfunction
    function! GitFlogSetupBuffer(root) abort
      call v:lua.GitFlogSetupBuffer(a:root)
    endfunction
    function! GitFlogComplete(lead, line, pos) abort
      return v:lua.GitFlogComplete(a:lead, a:line, a:pos)
    endfunction
  ]])
  vim.g.flog_backend_is_git_buf_fn = 'GitFlogIsGitBuf'
  vim.g.flog_backend_get_git_dir_fn = 'GitFlogGitDir'
  vim.g.flog_backend_setup_git_buffer_fn = 'GitFlogSetupBuffer'
  vim.g.flog_backend_complete_fn = 'GitFlogComplete'
  vim.g.flog_backend_user_cmd = 'Git'
  vim.g.flog_backend_user_split_cmd = 'Gsplit'
  local group = vim.api.nvim_create_augroup('GitFlogBackend', { clear = true })
  vim.api.nvim_create_autocmd('User', { group = group, pattern = 'FugitiveChanged', callback = function(ev)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == 'floggraph'
        and (not ev.data or not ev.data.work_tree or vim.b[buf].fugitive_work_tree == ev.data.work_tree) then
        vim.api.nvim_buf_call(buf, function() pcall(vim.cmd, 'Flogupdate') end)
      end
    end
  end })
end
function M.open(revision)
  if vim.fn.exists(':Flogsplit') ~= 2 then
    require('lazy').load({ plugins = { 'vim-flog' } })
  end
  -- The command also resolves Lazy’s placeholder before invoking Flog.
  local args = '-open-cmd=vertical\\ rightbelow\\ 60vsplit'
  if revision then args = args .. ' -rev=' .. vim.fn.fnameescape(revision) end
  vim.cmd('Flogsplit ' .. args)
  return vim.api.nvim_get_current_buf()
end
return M
