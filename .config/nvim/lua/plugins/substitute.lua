return {
  "gbprod/substitute.nvim",
  event = "VeryLazy",
  keys = {
    { "s", function() require('substitute').operator({ modifiers = { 'reindent' } }) end, mode = { "n" }, noremap = true, },
    { "ss", function() require('substitute').line({ modifiers = { 'reindent' } }) end, mode = { "n" }, noremap = true, },
    { "S", function() require('substitute').eol({ modifiers = { 'reindent' } }) end, mode = { "n" }, noremap = true, },
    { "<leader>s", function() require('substitute.range').operator() end, mode = { "n" }, noremap = true, },
    { "<leader>s", function() require('substitute.range').visual() end, mode = { "x" }, noremap = true, },
    { "<leader>ss", function() require('substitute.range').word() end, mode = { "n" }, noremap = true, },
    { "sx", function() require('substitute.exchange').operator() end, mode = { "n" }, noremap = true, },
    { "sxx", function() require('substitute.exchange').line() end, mode = { "n" }, noremap = true, },
    { "X", function() require('substitute.exchange').visual() end, mode = { "x" }, noremap = true, },
    { "sxc", function() require('substitute.exchange').cancel() end, mode = { "n" }, noremap = true, },
  },
  opts = {
    on_substitute = require("yanky.integration").substitute(),
    yank_substituted_text = false,
    preserve_cursor_position = true,
    modifiers = nil,
    highlight_substituted_text = {
      enabled = true,
      timer = 500,
    },
    range = {
      prefix = "S",
      prompt_current_text = true,
      confirm = false,
      complete_word = false,
      subject = nil,
      range = nil,
      suffix = "",
      auto_apply = false,
      cursor_position = "end",
    },
    exchange = {
      motion = false,
      use_esc_to_cancel = true,
      preserve_cursor_position = false,
    },
  }
}
