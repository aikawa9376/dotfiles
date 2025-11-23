local M = {}

local winid_in = nil
local float_autocmd_group_id = nil
local float_original_opts = nil
local float_is_focused = false

function M.open_float(bufnr, opts)
  opts = opts or {}

  -- Center the floating window
  local width = math.floor(vim.o.columns * 0.6)
  local height = math.floor(vim.o.lines * 0.5)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local win_opts = {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    border = "single",
    style = "minimal",
    title = " send ai argent ",
    title_pos = 'center',
  }

  if not winid_in or not vim.api.nvim_win_is_valid(winid_in) then
    winid_in = vim.api.nvim_open_win(bufnr, true, win_opts)
  else
    -- If window exists, just set buffer and focus
    vim.api.nvim_win_set_buf(winid_in, bufnr)
    vim.api.nvim_set_current_win(winid_in)
  end

  -- Setup focus-change behavior for floating window:
  -- shrink to bottom-right when focus leaves, and restore original size when focus returns.
  if float_autocmd_group_id then
    pcall(vim.api.nvim_del_augroup_by_id, float_autocmd_group_id)
    float_autocmd_group_id = nil
  end

  float_original_opts = {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    border = win_opts.border,
    style = win_opts.style,
    title = win_opts.title,
    title_pos = win_opts.title_pos,
  }
  float_is_focused = true

  local function shrink_float()
    if not winid_in or not vim.api.nvim_win_is_valid(winid_in) then return end
    local cols = vim.o.columns
    local lines = vim.o.lines
    -- Small size and place in bottom-right corner
    local w = math.max(10, math.floor(cols * 0.25))
    local h = math.max(3, math.floor(lines * 0.2))
    local r = math.max(0, lines - h - 2)
    local c = math.max(0, cols - w)
    local cfg = {
      relative = "editor",
      row = r,
      col = c,
      width = w,
      height = h,
      border = float_original_opts.border,
      style = float_original_opts.style,
      title = float_original_opts.title,
      title_pos = float_original_opts.title_pos,
    }
    pcall(function() vim.api.nvim_win_set_config(winid_in, cfg) end)
  end

  local function restore_float()
    if not winid_in or not vim.api.nvim_win_is_valid(winid_in) then return end
    pcall(function() vim.api.nvim_win_set_config(winid_in, float_original_opts) end)
  end

  local gid = vim.api.nvim_create_augroup("SendAgentFloat" .. tostring(winid_in), { clear = true })
  float_autocmd_group_id = gid
  vim.api.nvim_create_autocmd("WinEnter", {
    group = gid,
    callback = function()
      local curr = vim.api.nvim_get_current_win()
      if curr == winid_in then
        -- When floating window regains focus, restore original position/size and enter insert.
        if not float_is_focused then
          restore_float()
          float_is_focused = true
          pcall(vim.cmd, "startinsert")
        end
      else
        -- When focus moves away, shrink and move it to the bottom-right.
        if float_is_focused then
          shrink_float()
          float_is_focused = false
        end
      end
    end,
  })

  vim.wo[winid_in].rnu = false
  vim.wo[winid_in].number = false
  vim.wo[winid_in].cursorline = true
  vim.wo[winid_in].wrap = true

  vim.cmd("startinsert") -- Start in insert mode

  return winid_in
end

function M.open_vsplit(bufnr, opts)
  opts = opts or {}
  -- If a float autocmd group is active, clear it as we are switching to vsplit mode.
  if float_autocmd_group_id then
    pcall(vim.api.nvim_del_augroup_by_id, float_autocmd_group_id)
    float_autocmd_group_id = nil
    float_original_opts = nil
    float_is_focused = false
  end
  local width = math.floor(vim.o.columns * 0.5)

  if winid_in and vim.api.nvim_win_is_valid(winid_in) then
    vim.api.nvim_win_set_buf(winid_in, bufnr)
    vim.api.nvim_set_current_win(winid_in)
  else
    vim.cmd("vsplit")
    vim.api.nvim_win_set_width(0, width)
    winid_in = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(winid_in, bufnr)
  end

  vim.wo[winid_in].rnu = false
  vim.wo[winid_in].number = false
  vim.wo[winid_in].cursorline = true
  vim.wo[winid_in].wrap = true
  vim.cmd("startinsert")
  return winid_in
end

function M.open(bufnr, opts)
  opts = opts or {}
  local window_type = opts.window_type or "float"

  if window_type == "vsplit" then
    return M.open_vsplit(bufnr, opts)
  else
    return M.open_float(bufnr, opts)
  end
end

function M.close()
  if winid_in and vim.api.nvim_win_is_valid(winid_in) then
    vim.api.nvim_win_close(winid_in, true)
    winid_in = nil
  end

  if float_autocmd_group_id then
    pcall(vim.api.nvim_del_augroup_by_id, float_autocmd_group_id)
    float_autocmd_group_id = nil
  end
  float_original_opts = nil
  float_is_focused = false
end

function M.is_open()
  return winid_in and vim.api.nvim_win_is_valid(winid_in)
end

function M.get_bufnr()
  if winid_in and vim.api.nvim_win_is_valid(winid_in) then
    return vim.api.nvim_win_get_buf(winid_in)
  end
  return nil
end

return M
