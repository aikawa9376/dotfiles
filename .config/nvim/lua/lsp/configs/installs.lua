local lspconfig = require "lspconfig"
local configs = require "lspconfig.configs"
local servers = require "nvim-lsp-installer.servers"
local server = require "nvim-lsp-installer.server"
local npm = require "nvim-lsp-installer.installers.npm"
local root_dir, executable_path, default_probe_dir

root_dir = server.get_server_root_path('ls_emmet')
executable_path = npm.executable(root_dir, "ls_emmet")
configs.ls_emmet = {
  default_config = {
    filetypes = {'html', 'css', 'scss', 'twig', 'php'};
    root_dir = lspconfig.util.root_pattern ".git",
  },
}
local ls_emmet = server.Server:new {
-- require'lspinstall/servers'.emmet = {
  name = 'ls_emmet',
  installer = npm.packages { "ls_emmet" },
  root_dir = root_dir,
  default_options = {
    cmd = {executable_path, '--stdio'};
  };
}
servers.register(ls_emmet)

root_dir = server.get_server_root_path('angularls')
executable_path = npm.executable(root_dir, "ngserver")
default_probe_dir = root_dir .. '/node_modules'
configs.angularls = {
  default_config = {
    filetypes = { "typescript", "html" },
    root_dir = lspconfig.util.root_pattern ".git",
  },
}
local new_anglar = server.Server:new {
  name = 'angularls',
  languages = { "angular" },
  installer = npm.packages { "@angular/language-server", "typescript" },
  root_dir = root_dir;
  default_options = {
    cmd = {
        executable_path,
        "--stdio",
        "--tsProbeLocations",
        default_probe_dir,
        "--ngProbeLocations",
        default_probe_dir .. '/@angular/language-server/',
    },
  },
}
servers.register(new_anglar)
