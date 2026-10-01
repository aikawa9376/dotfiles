local MyAutoCmd = vim.api.nvim_create_augroup("MyAutoCmd", { clear = true })

vim.cmd("filetype plugin indent on")

local function valid_buffer(bufnr)
  return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

local function buffer_is_application(bufnr)
  return valid_buffer(bufnr)
    and (vim.api.nvim_buf_get_name(bufnr) == ""
      or vim.bo[bufnr].buftype ~= ""
      or not vim.bo[bufnr].buflisted)
end

local function application_buffer_is_disposable(bufnr)
  return buffer_is_application(bufnr)
    and not vim.bo[bufnr].modified
    and not (vim.b[bufnr] and vim.b[bufnr].lazyagent_is_scratch == true)
end

local function no_name_buffer_should_prune(bufnr)
  return application_buffer_is_disposable(bufnr)
    and vim.api.nvim_buf_get_name(bufnr) == ""
    and vim.bo[bufnr].buftype == ""
    and #vim.fn.win_findbuf(bufnr) == 0
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

local function window_path(node, winid, path)
  if node[1] == "leaf" then return node[2] == winid end
  for index, child in ipairs(node[2]) do
    path[#path + 1] = { node, index }
    if window_path(child, winid, path) then return true end
    path[#path] = nil
  end
  return false
end

local function branch_windows(node, windows)
  if node[1] == "leaf" then
    windows[#windows + 1] = node[2]
  else
    for _, child in ipairs(node[2]) do branch_windows(child, windows) end
  end
  return windows
end

local function disposable_branch(node, current_win)
  local windows = branch_windows(node, {})
  for _, winid in ipairs(windows) do
    if winid == current_win or not vim.api.nvim_win_is_valid(winid)
      or vim.api.nvim_win_get_config(winid).relative ~= ""
      or not application_buffer_is_disposable(vim.api.nvim_win_get_buf(winid)) then
      return nil
    end
  end
  return #windows > 0 and windows or nil
end

local function close_branch(windows)
  for _, winid in ipairs(windows) do
    if vim.api.nvim_win_is_valid(winid) then vim.api.nvim_win_close(winid, true) end
  end
end

local function close_application_split_or_run_q()
  local bufnr, current_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  if not buffer_is_application(bufnr) then
    local path = {}
    if window_path(vim.fn.winlayout(), current_win, path) then
      -- Close the nearest eligible branch above or below first.
      for depth = #path, 1, -1 do
        local node, index = unpack(path[depth])
        if node[1] == "col" then
          for distance = 1, #node[2] do
            for _, sibling_index in ipairs({ index + distance, index - distance }) do
              local windows = node[2][sibling_index]
                and disposable_branch(node[2][sibling_index], current_win)
              if windows then close_branch(windows); return end
            end
          end
        end
      end

      -- Otherwise close the leftmost eligible branch beside it.
      local candidates = {}
      for depth = #path, 1, -1 do
        local node, index = unpack(path[depth])
        if node[1] == "row" then
          for sibling_index, sibling in ipairs(node[2]) do
            local windows = sibling_index ~= index and disposable_branch(sibling, current_win)
            if windows then
              local left = math.huge
              for _, winid in ipairs(windows) do
                left = math.min(left, vim.api.nvim_win_get_position(winid)[2])
              end
              candidates[#candidates + 1] = { left, windows }
            end
          end
        end
      end
      table.sort(candidates, function(a, b) return a[1] < b[1] end)
      if candidates[1] then close_branch(candidates[1][2]); return end
    end
  end
  vim.api.nvim_feedkeys("q", "n", false)
end

vim.keymap.set("n", "q", close_application_split_or_run_q, {
  silent = true,
  desc = "Close an application split or run the native q key",
})

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
ft_keymap('noice', 'n', '<ESC>', '<C-w>c', { nowait = true })
ft_keymap({ 'help', 'qf', 'fugitive', 'defx', 'vista', 'neo-tree' }, 'n', '<C-c>', '<C-w>c', { nowait = true })
ft_keymap('gitcommit', 'n', 'q', ':<c-u>wq<CR>', { nowait = true })
ft_keymap('gitcommit', 'n', '<C-c>', ':<c-u>wq<CR>', { nowait = true })
ft_keymap({ 'Avante', 'AvanteInput', 'AvanteSelectedFiles' }, 'n', 'q', ':AvanteToggle<CR>', { nowait = true, silent = true })
ft_keymap('AvantePromptInput', 'n', '<ESC>', '<C-w>c')
ft_keymap('OverseerList', 'n', 'q', ':OverseerClose<CR>', { nowait = true, silent = true })
