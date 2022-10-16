local lspconfig = require "lspconfig"
local configs = require "lspconfig.configs"
local servers = require "mason.servers"
local server = require "mason.server"
local npm = require "mason.installers.npm"
local root_dir, default_probe_dir

root_dir = server.get_server_root_path('ls_emmet')
configs.ls_emmet = {
  default_config = {
    filetypes = { 'html', 'css', 'scss', 'twig', 'php' };
    root_dir = lspconfig.util.root_pattern ".git",
  },
}
local ls_emmet = server.Server:new {
  -- require'lspinstall/servers'.emmet = {
  name = 'ls_emmet',
  installer = npm.packages { "ls_emmet" },
  root_dir = root_dir,
  default_options = {
    cmd = { 'ls_emmet', '--stdio' },
    cmd_env = npm.env(root_dir),
  };
}
servers.register(ls_emmet)

root_dir = server.get_server_root_path('angularls')
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
      "ngserver",
      "--stdio",
      "--tsProbeLocations",
      default_probe_dir,
      "--ngProbeLocations",
      default_probe_dir .. '/@angular/language-server/',
    },
    cmd_env = npm.env(root_dir),
  },
}
servers.register(new_anglar)
