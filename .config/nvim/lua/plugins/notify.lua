return {
  "rcarriga/nvim-notify",
  lazy = true,
  opts = {
    on_open = function (win)
      vim.api.nvim_win_set_config(win, { focusable = false })
    end,
    max_width = 100,
    top_down = false,
    background_colour = '#002b36'
  }
}
