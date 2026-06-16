local MyAutoCmd = vim.api.nvim_create_augroup("MyAutoCmd", { clear = true })

vim.cmd("filetype plugin indent on")

local function no_name_buffer_should_prune(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  if (vim.api.nvim_buf_get_name(bufnr) or "") ~= "" then
    return false
  end
  if vim.bo[bufnr].buftype ~= "" then
    return false
  end
  if vim.b[bufnr] and vim.b[bufnr].lazyagent_is_scratch == true then
    return false
  end
  if vim.bo[bufnr].modified then
    return false
  end
  return #vim.fn.win_findbuf(bufnr) == 0
end

local function prune_orphaned_no_name_buffers()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if no_name_buffer_should_prune(bufnr) then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end
end

local function schedule_no_name_prune()
  vim.schedule(prune_orphaned_no_name_buffers)
end

vim.api.nvim_create_autocmd({ "BufHidden", "WinClosed" }, {
  group = MyAutoCmd,
  pattern = "*",
  callback = schedule_no_name_prune,
})

vim.api.nvim_create_autocmd("InsertLeave", {
  group = MyAutoCmd,
  pattern = "*",
  callback = function()
    vim.o.paste = false
  end,
})

-- Do not keep canceled or failed command-line entries.
vim.api.nvim_create_autocmd("CmdlineLeave", {
  group = MyAutoCmd,
  pattern = ":",
  callback = function()
    local cmd = vim.fn.getcmdline()
    local exit_key = vim.v.char

    if exit_key == "\r" then
      vim.v.errmsg = ""
    end

    vim.schedule(function()
      if cmd == "" or vim.fn.histget("cmd", -1) ~= cmd then
        return
      end

      if exit_key ~= "\r" or vim.v.errmsg ~= "" then
        vim.fn.histdel("cmd", -1)
      end
    end)
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

-- terminal fzf only feature
vim.api.nvim_create_autocmd("BufEnter", {
  group = MyAutoCmd,
  pattern = "*",
  callback = function()
    if vim.bo.buftype == 'terminal' and vim.bo.filetype == 'fzf' then
      vim.cmd("startinsert")
    end

    -- terminal fzf-lua exec_silent hack
    local last_filetype = vim.fn.getbufvar(vim.fn.bufnr('#'), '&filetype', '')
    if last_filetype == 'fzf' then
      vim.o.number = true
      vim.o.numberwidth = 1
      vim.o.signcolumn = "yes"
      vim.o.statuscolumn = "%C%l%s"
    end
  end,
})

-- diff mode settings
---@diagnostic disable: param-type-mismatch
vim.api.nvim_create_autocmd('OptionSet', {
  group = MyAutoCmd,
  pattern = 'diff',
  callback = function(ev)
    if vim.wo.diff then
      vim.api.nvim_set_hl(ev.buf, "NormalNC", { bg = "None" })
      vim.diagnostic.enable(false, { bufnr = ev.buf })
      vim.keymap.set('n', 'q', ':tabclose<CR>', { buffer = ev.buf, nowait = true, silent = true })
      vim.keymap.set("n", "]]", function()
        require("gitsigns").nav_hunk('next', { target = 'all' })
      end, { buffer = ev.buf, nowait = true, silent = true })
      vim.keymap.set("n", "[[", function()
        require("gitsigns").nav_hunk('prev', { target = 'all' })
      end, { buffer = ev.buf, nowait = true, silent = true })
    else
      vim.api.nvim_set_hl(ev.buf, "NormalNC", { bg = "#073642" })
    end
  end,
})

-- Filetype-specific keymaps
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
ft_keymap('fugitive', 'n', 'o', '<Plug>fugitive:=')
ft_keymap('fugitive', 'n', 'i', '<Plug>fugitive:izt')
ft_keymap('fugitive', 'n', 's', '<Plug>fugitive:-', { nowait = true })
ft_keymap('fugitive', 'n', 'S', '<Cmd>G add -A<CR>', { nowait = true })
ft_keymap('fugitive', 'n', 'A', '<Plug>fugitive:ce', { nowait = true, remap = true })
ft_keymap('fugitive', 'n', 'cl', '<Cmd>Gstash<CR>', { nowait = true, remap = true })
ft_keymap('fugitive', 'n', ']]', '<Plug>fugitive:<<Plug>fugitive:]/<Plug>fugitive:>', { nowait = true })
ft_keymap('fugitive', 'n', '[[', '<Plug>fugitive:<<Plug>fugitive:[/<Plug>fugitive:>', { nowait = true })
ft_keymap('fugitive', { 'n', 'x' }, 'gE', '<Plug>fugitive:gI', { nowait = true })
ft_keymap('fugitive', { 'n', 'x' }, 'gI', '3<Plug>fugitive:gI', { nowait = true })
ft_keymap('fugitiveblame', 'n', 'q', 'gq', { nowait = true, remap = true })
ft_keymap('fugitiveblame', 'n', '<BS>', '<C-w><C-w>[o<Leader>gb', { nowait = true, remap = true })
ft_keymap('git', 'n', ']]', '<Cmd>silent! normal! zc<CR>]/<Cmd>normal! zo<CR>', { nowait = true, remap = true })
ft_keymap('git', 'n', '[[', '<Cmd>silent! normal! zc<CR>[/<Cmd>normal! zo<CR>', { nowait = true, remap = true })
ft_keymap('git', 'n', 'o', 'za', { nowait = true, remap = true })
ft_keymap('git', 'n', 'i', '<Plug>fugitive:)zt', { nowait = true, remap = true })
ft_keymap({ 'fugitiveblame', 'git' }, 'n', '<CR>', '<Plug>fugitive:O', { nowait = true, remap = true })
ft_keymap({ 'fugitivestash', 'fugitivebranch' }, 'n', 'q', function () require"utilities".smart_close() end, { nowait = true, remap = true })
ft_keymap('noice', 'n', '<ESC>', '<C-w>c', { nowait = true })
ft_keymap({ 'help', 'qf', 'fugitive', 'defx', 'vista', 'neo-tree' }, 'n', '<C-c>', '<C-w>c', { nowait = true })
ft_keymap('gitcommit', 'n', 'q', ':<c-u>wq<CR>', { nowait = true })
ft_keymap('gitcommit', 'n', '<C-c>', ':<c-u>wq<CR>', { nowait = true })
ft_keymap({ 'Avante', 'AvanteInput', 'AvanteSelectedFiles' }, 'n', 'q', ':AvanteToggle<CR>', { nowait = true, silent = true })
ft_keymap('AvantePromptInput', 'n', '<ESC>', '<C-w>c')
ft_keymap('OverseerList', 'n', 'q', ':OverseerClose<CR>', { nowait = true, silent = true })
