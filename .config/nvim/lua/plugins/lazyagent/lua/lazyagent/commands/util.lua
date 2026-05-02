local M = {}

function M.create(name, fn, opts)
  pcall(function()
    vim.api.nvim_create_user_command(name, fn, opts)
  end)
end

function M.delete(name)
  pcall(function()
    vim.api.nvim_del_user_command(name)
  end)
end

function M.arg(cmdargs)
  return (cmdargs and cmdargs.args and cmdargs.args ~= "") and cmdargs.args or nil
end

return M
