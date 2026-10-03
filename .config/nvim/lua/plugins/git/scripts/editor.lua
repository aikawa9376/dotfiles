local channel = vim.fn.sockconnect('pipe', vim.env.GIT_NVIM_SERVER, { rpc = true })
if channel <= 0 then vim.cmd('cquit 1') end
local token = tostring(vim.uv.os_getpid())
local repository = vim.system({ 'git', 'rev-parse', '--show-toplevel' }, { text = true }):wait()
local root = repository.code == 0 and vim.trim(repository.stdout) or nil
local ok = pcall(vim.rpcrequest, channel, 'nvim_exec_lua', "require('git.editor').open(...)", { arg[1], token, root })
if not ok then vim.cmd('cquit 1') end
local failed = false
local finished = vim.wait(24 * 60 * 60 * 1000, function()
  local success, pending = pcall(vim.rpcrequest, channel, 'nvim_exec_lua', "return require('git.editor').pending[...]", { token })
  if not success or pending == 'error' then failed = true; return true end
  return not pending or pending == vim.NIL
end, 100)
vim.fn.chanclose(channel)
if failed or not finished then vim.cmd('cquit 1') end
