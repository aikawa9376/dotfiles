local MyAutoCmd = vim.api.nvim_create_augroup("MyAutoCmd", { clear = true })

vim.cmd("filetype plugin indent on")

vim.api.nvim_create_autocmd("InsertLeave", {
  group = MyAutoCmd,
  pattern = "*",
  callback = function()
    vim.o.paste = false
  end,
})

-- lualine for fzf
vim.api.nvim_create_autocmd("FileType", {
  group = MyAutoCmd,
  pattern = "fzf",
  callback = function()
    vim.opt.laststatus = 0
    vim.opt.showmode = false
    vim.opt.ruler = false
    vim.opt.showcmd = false
  end,
})
vim.api.nvim_create_autocmd("BufLeave", {
  group = MyAutoCmd,
  pattern = "*",
  callback = function()
    vim.opt.laststatus = 3
    vim.opt.showmode = true
    vim.opt.ruler = true
    vim.opt.showcmd = true
  end,
})

-- terminal mode
if vim.fn.exists(":terminal") == 2 then
  vim.api.nvim_create_autocmd("TermOpen", {
    group = MyAutoCmd,
    pattern = "*",
    callback = function(ev)
      local bufnr = ev.buf or 0
      vim.keymap.set("n", "<ESC>", ":close<CR>", { buffer = bufnr, silent = true, nowait = true })
    end,
  })
end

-- diff mode settings
vim.api.nvim_create_autocmd('OptionSet', {
  group = MyAutoCmd,
  pattern = 'diff',
  callback = function(ev)
    if vim.wo.diff then
      vim.api.nvim_set_hl(ev.buf, "NormalNC", { bg = "None" })
      vim.diagnostic.enable(false, { bufnr = ev.buf })
      vim.keymap.set('n', 'q', ':tabclose<CR>', { buffer = ev.buf, nowait = true, silent = true })
    else
      vim.api.nvim_set_hl(ev.buf, "NormalNC", { bg = "#073642" })
    end
  end,
})

local function ft_keymap(filetypes, mode, lhs, rhs, opts)
  opts = opts or {}
  vim.api.nvim_create_autocmd('FileType', {
    group = MyAutoCmd,
    pattern = filetypes,
    callback = function(ev)
      local map_opts = vim.tbl_extend('force', { buffer = ev.buf }, opts)
      vim.keymap.set(mode, lhs, rhs, map_opts)
    end,
  })
end

ft_keymap({ 'help', 'qf' }, 'n', '<CR>', '<CR>')
ft_keymap({ 'help', 'qf', 'fugitive' }, 'n', 'q', '<C-w>c', { nowait = true })
ft_keymap('fugitiveblame', 'n', 'q', 'gq', { nowait = true, remap = true })
ft_keymap('fugitiveblame', 'n', '<BS>', '<C-w><C-w>[o<Leader>gb', { nowait = true, remap = true })
ft_keymap({ 'fugitiveblame', 'git' }, 'n', '<CR>', 'O', { nowait = true, remap = true })
ft_keymap({ 'fugitiveblame', 'git' }, 'n', 'o', 'za', { nowait = true, remap = true })
ft_keymap('noice', 'n', '<ESC>', '<C-w>c', { nowait = true })
ft_keymap({ 'help', 'qf', 'fugitive', 'defx', 'vista', 'neo-tree' }, 'n', '<C-c>', '<C-w>c', { nowait = true })
ft_keymap('gitcommit', 'n', 'q', ':<c-u>wq<CR>', { nowait = true })
ft_keymap('gitcommit', 'n', '<C-c>', ':<c-u>wq<CR>', { nowait = true })
ft_keymap('fugitive', 'n', '<Space>gp', ':<c-u>Git! push<CR><C-w>c')
ft_keymap({ 'Avante', 'AvanteInput', 'AvanteSelectedFiles' }, 'n', 'q', ':AvanteToggle<CR>', { nowait = true, silent = true })
ft_keymap('AvantePromptInput', 'n', '<ESC>', '<C-w>c')
ft_keymap('OverseerList', 'n', 'q', ':OverseerClose<CR>', { nowait = true, silent = true })

vim.api.nvim_create_user_command("TermForceCloseAll", function()
  local term_bufs = vim.tbl_filter(function(buf)
    return vim.api.nvim_get_option_value("buftype", { buf = buf }) == "terminal"
  end, vim.api.nvim_list_bufs())

  for _, t in ipairs(term_bufs) do
    vim.cmd("bd! " .. t)
  end
end, {})
