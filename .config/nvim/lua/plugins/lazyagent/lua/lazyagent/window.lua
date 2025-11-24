local M = {}

local winid = nil
local float_autocmd_group_id = nil
local float_original_opts = nil
local float_is_focused = false

local function _ensure_bufnr(bufnr, opts)
  -- Normalize accepting either (bufnr, opts) or (opts) as the first parameter.
  if type(bufnr) == "table" and opts == nil then
    opts = bufnr
    bufnr = nil
  end

  -- If the caller didn't pass a valid buffer, create a scratch buffer to avoid nvim_open_win assertion errors.
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    bufnr = vim.api.nvim_create_buf(false, true)
    pcall(function()
      vim.bo[bufnr].bufhidden = "wipe"
      vim.bo[bufnr].buftype = "nofile"
      vim.bo[bufnr].filetype = (opts and opts.filetype) or "markdown"
      vim.bo[bufnr].modifiable = true
    end)
  end

  return bufnr, opts
end

function M.open_float(bufnr, opts)
  -- Ensure we always get a valid buffer and canonical opts table.
  bufnr, opts = _ensure_bufnr(bufnr, opts or {})

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
    title = opts.title or " lazyagent ",
    title_pos = "center",
  }

  if not winid or not vim.api.nvim_win_is_valid(winid) then
    winid = vim.api.nvim_open_win(bufnr, true, win_opts)
  else
    -- If window exists, just set buffer and focus
    vim.api.nvim_win_set_buf(winid, bufnr)
    vim.api.nvim_set_current_win(winid)
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
    if not winid or not vim.api.nvim_win_is_valid(winid) then return end
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
    pcall(function() vim.api.nvim_win_set_config(winid, cfg) end)
  end

    local function restore_float()
    if not winid or not vim.api.nvim_win_is_valid(winid) then return end
    pcall(function() vim.api.nvim_win_set_config(winid, float_original_opts) end)
  end

  local gid = vim.api.nvim_create_augroup("LazyAgentFloat" .. tostring(winid), { clear = true })
  float_autocmd_group_id = gid
  vim.api.nvim_create_autocmd("WinEnter", {
    group = gid,
    callback = function()
      local curr = vim.api.nvim_get_current_win()
      if curr == winid then
        -- When floating window regains focus, restore original position/size and enter insert.
        if not float_is_focused then
          restore_float()
          float_is_focused = true
          if opts and opts.start_in_insert_on_focus then
            pcall(function() vim.cmd("startinsert") end)
          end
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

  vim.wo[winid].rnu = false
  vim.wo[winid].number = false
  vim.wo[winid].cursorline = true
  vim.wo[winid].wrap = true

  if opts and opts.start_in_insert_on_focus then
    vim.cmd("startinsert") -- Start in insert mode
  end
end

function M.open_vsplit(bufnr, opts)
  -- Ensure we always get a valid buffer and canonical opts table.
  bufnr, opts = _ensure_bufnr(bufnr, opts or {})
  -- If a float autocmd group is active, clear it as we are switching to vsplit mode.
  if float_autocmd_group_id then
    pcall(vim.api.nvim_del_augroup_by_id, float_autocmd_group_id)
    float_autocmd_group_id = nil
    float_original_opts = nil
    float_is_focused = false
  end
  local width = math.floor(vim.o.columns * 0.5)

  if winid and vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_win_set_buf(winid, bufnr)
    vim.api.nvim_set_current_win(winid)
  else
    vim.cmd("vsplit")
    vim.api.nvim_win_set_width(vim.api.nvim_get_current_win(), width)
    winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(winid, bufnr)
  end

  vim.wo[winid].rnu = false
  vim.wo[winid].number = false
  vim.wo[winid].cursorline = true
  vim.wo[winid].wrap = true
  if opts and opts.start_in_insert_on_focus then
    vim.cmd("startinsert")
  end
  return winid
end

function M.open(bufnr, opts)
  -- Accept either (bufnr, opts) or (opts) calling style and ensure a valid buffer/opts.
  if type(bufnr) == "table" and opts == nil then
    opts = bufnr
    bufnr = nil
  end
  bufnr, opts = _ensure_bufnr(bufnr, opts or {})
  local window_type = opts.window_type or "float"

  if window_type == "vsplit" then
    return M.open_vsplit(bufnr, opts)
  else
    return M.open_float(bufnr, opts)
  end
end

function M.close()
  if winid and vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_win_close(winid, true)
    winid = nil
  end

  if float_autocmd_group_id then
    pcall(vim.api.nvim_del_augroup_by_id, float_autocmd_group_id)
    float_autocmd_group_id = nil
  end
  float_original_opts = nil
  float_is_focused = false
end

function M.is_open()
  return winid and vim.api.nvim_win_is_valid(winid)
end

function M.get_bufnr()
  if winid and vim.api.nvim_win_is_valid(winid) then
    return vim.api.nvim_win_get_buf(winid)
  end
  return nil
end

return M
