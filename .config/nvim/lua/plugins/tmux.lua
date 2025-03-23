return {
  "aserowy/tmux.nvim",
  keys = {
    { "<C-w>h", function () require('tmux').move_left() end, silent = true },
    { "<C-w>j", function () require('tmux').move_bottom() end, silent = true },
    { "<C-w>k", function () require('tmux').move_top() end, silent = true },
    { "<C-w>l", function () require('tmux').move_right() end, silent = true },
    { "<C-w><", function () require('tmux').resize_left() end, silent = true },
    { "<C-w>+", function () require('tmux').resize_bottom() end, silent = true },
    { "<C-w>-", function () require('tmux').resize_top() end, silent = true },
    { "<C-w>>", function () require('tmux').resize_right() end, silent = true },
  },
  opts = {
    copy_sync = {
      enable = false,
    },
    navigation = {
      enable_default_keybindings = false,
    },
    resize = {
      enable_default_keybindings = false,
      resize_step_x = 3,
      resize_step_y = 3,
    }
  }
}
