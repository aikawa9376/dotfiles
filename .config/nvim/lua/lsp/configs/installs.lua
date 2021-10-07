-- angular hack
local config = require"lspinstall/util".extract_config("angularls")

local cmd = { "./node_modules/.bin/ngserver", "--stdio", "--tsProbeLocations",  "./node_modules", "--ngProbeLocations", "./node_modules" }

config.default_config.cmd = cmd
config.default_config.on_new_config = function(new_config, new_root_dir)
    new_config.cmd = cmd
end

config.install_script = [[
  ! test -f package.json && npm init -y --scope=lspinstall || true
  npm install @angular/language-server @angular/language-service typescript
  ]]

require'lspinstall/servers'.angular = config

-- emmet hack
require'lspinstall/servers'.emmet = {
  default_config = {
    cmd = {'./node_modules/.bin/ls_emmet', '--stdio'};
    filetypes = {'html', 'css', 'scss', 'twig', 'php'};
    root_dir = function(fname)
      return vim.loop.cwd()
    end;
    settings = {};
  };
  install_script = [[
  ! test -f package.json && npm init -y --scope=lspinstall || true
  npm install ls_emmet
  ]];
}
