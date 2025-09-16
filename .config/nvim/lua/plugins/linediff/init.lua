return {
  "linediff",
  dir = os.getenv("XDG_CONFIG_HOME") .. "/nvim/lua/plugins/linediff",
  cmd = "Linediff",
  init = function()
    vim.g.linediff_buffer_type = 'scratch'
  end,
  config = true
}
