local is_linux = vim.uv.os_uname().sysname == 'Linux'
local jemalloc = '/usr/lib/libjemalloc.so.2'
local cmd_env
if is_linux and vim.fn.filereadable(jemalloc) == 1 then
  -- Purge unused pages on free so idle LuaLS does not retain its diagnostic peak.
  cmd_env = {
    LD_PRELOAD = jemalloc .. (vim.env.LD_PRELOAD and ' ' .. vim.env.LD_PRELOAD or ''),
    MALLOC_CONF = (vim.env.MALLOC_CONF and vim.env.MALLOC_CONF .. ',' or '')
      .. 'dirty_decay_ms:0,muzzy_decay_ms:0',
  }
end

---@type vim.lsp.Config
return {
  -- LuaLS workers can exit on epoll EINTR after Linux process suspension.
  cmd = is_linux and {
    'lua-language-server',
    vim.fn.stdpath('config') .. '/lua/lsp/lua_ls_bootstrap.lua',
  } or nil,
  cmd_env = cmd_env,
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
