---@type vim.lsp.Config
return {
  -- LuaLS workers can exit on epoll EINTR after Linux process suspension.
  cmd = vim.uv.os_uname().sysname == 'Linux' and {
    'lua-language-server',
    vim.fn.stdpath('config') .. '/lua/lsp/lua_ls_bootstrap.lua',
  } or nil,
  settings = {
    Lua = {
      hint = {
        enable = true,
        arrayIndex = "Disable",
        semicolon = "Disable"
      },
      diagnostics = {
        globals = { "vim" },
      },
      -- very slow and very use resource
      codeLens = {
        enable = false,
      },
      runtime = {
        version = "LuaJIT",
        path = vim.split(package.path, ";"),
      },
    },
  },
  on_attach = function(client, bufnr)
    client.server_capabilities.documentFormattingProvider = false
    require('lsp.default').settings(client, bufnr)
  end,
}
