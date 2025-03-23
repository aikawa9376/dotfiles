return {
  "Shougo/junkfile.vim",
  cmd = "JunkfileOpen",
  init = function ()
    local workdir
    if vim.fn.exists('*FindRootDirectory') == 1 and vim.fn.FindRootDirectory() ~= '' then
      local dir = vim.fn.FindRootDirectory()
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
