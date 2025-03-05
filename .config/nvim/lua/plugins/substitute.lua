require("substitute").setup({
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
})

vim.keymap.set("n", "<Leader>r", function()
  require('substitute').operator()
end, { noremap = true })
vim.keymap.set("n", "<Leader>rr", function()
  require('substitute').line()
end, { noremap = true })
vim.keymap.set("n", "<Leader>R", function()
  require('substitute').eol()
end, { noremap = true })
vim.keymap.set("n", "s", function()
  require('substitute').operator({ modifiers = { 'reindent' } })
end, { noremap = true })
vim.keymap.set("n", "ss", function()
  require('substitute').line({ modifiers = { 'reindent' } })
end, { noremap = true })
vim.keymap.set("n", "S", function()
  require('substitute').eol({ modifiers = { 'reindent' } })
end, { noremap = true })

vim.keymap.set("n", "<leader>s", require('substitute.range').operator, { noremap = true })
vim.keymap.set("x", "<leader>s", require('substitute.range').visual, { noremap = true })
vim.keymap.set("n", "<leader>ss", require('substitute.range').word, { noremap = true })

vim.keymap.set("n", "sx", require('substitute.exchange').operator, { noremap = true })
vim.keymap.set("n", "sxx", require('substitute.exchange').line, { noremap = true })
vim.keymap.set("x", "X", require('substitute.exchange').visual, { noremap = true })
vim.keymap.set("n", "sxc", require('substitute.exchange').cancel, { noremap = true })
