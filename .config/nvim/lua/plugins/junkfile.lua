return {
  "Shougo/junkfile.vim",
  cmd = "JunkfileOpen",
  init = function ()
    local workdir
    local project = require("project.api")
    local rootDir = pcall(project.get_project_root)

    if rootDir then
      local dir = project.get_project_root()
      local dir_parts = vim.split(dir, '/')
      workdir = '/' .. dir_parts[#dir_parts]
    else
      workdir = ''
    end
    vim.api.nvim_create_user_command('JunkfileOpen', function()
      vim.fn['junkfile#open_immediately'](os.date('%d.md'))
    end, { nargs = 0 })
    vim.g['junkfile#directory'] = os.getenv('XDG_CACHE_HOME') .. '/junkfile' .. workdir
  end
}
