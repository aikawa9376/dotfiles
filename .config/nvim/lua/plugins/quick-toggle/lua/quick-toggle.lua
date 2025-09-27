local M = {}

---@return number | nil
local function get_qf_win_id()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(win)].buftype == 'quickfix' then
      return win
    end
  end
  return nil
end

---@return 'quickfix' | 'location' | nil
local function get_active_list_type()
  local qf_win_id = get_qf_win_id()
  if not qf_win_id then
    return nil
  end

  local win_info = vim.fn.getwininfo(qf_win_id)[1]
  if win_info and win_info.loclist == 1 then
    return 'location'
  else
    return 'quickfix'
  end
end

local state = { last_closed = nil }

--- Quickfix/Locationリストを賢くトグルする関数
function M.toggle()
  local qf_win_id = get_qf_win_id()

  if qf_win_id then
    local win_info = vim.fn.getwininfo(qf_win_id)[1]
    if win_info and win_info.loclist == 1 then
      vim.cmd('lclose')
      state.last_closed = 'location'
    else
      vim.cmd('cclose')
      state.last_closed = 'quickfix'
    end
  else
    local can_open_qf = not vim.tbl_isempty(vim.fn.getqflist())
    local can_open_loc = not vim.tbl_isempty(vim.fn.getloclist(0))

    local cur_win = vim.api.nvim_get_current_win()
    local function open_list(cmd)
      vim.cmd(cmd)
      -- Restore previous window so focus doesn't move
      if vim.api.nvim_win_is_valid(cur_win) then
        vim.api.nvim_set_current_win(cur_win)
      end
    end

    if state.last_closed == 'location' and can_open_loc then
      open_list('lopen')
      state.last_closed = nil
    elseif state.last_closed == 'quickfix' and can_open_qf then
      open_list('copen')
      state.last_closed = nil
    elseif can_open_qf then
      open_list('copen')
    elseif can_open_loc then
      open_list('lopen')
    end
  end
end

local function notify_boundary(direction, list_name)
    local message
    if direction == 'next' then
        message = "Already at the last item in " .. list_name .. " list"
    else
        message = "Already at the first item in " .. list_name .. " list"
    end
    vim.notify(message, vim.log.levels.INFO, { title = "QuickToggle" })
end

--- 次の項目に移動
function M.next_item()
  local list_type = get_active_list_type()

  if list_type == 'quickfix' then
    local ok, _ = pcall(function() vim.cmd('cnext') end)
    if not ok then
      notify_boundary('next', 'quickfix')
    end
  elseif list_type == 'location' then
    local ok, _ = pcall(function() vim.cmd('lnext') end)
    if not ok then
      notify_boundary('next', 'location')
    end
  else
    if not vim.tbl_isempty(vim.fn.getqflist()) then
      local ok, _ = pcall(function() vim.cmd('cnext') end)
      if not ok then
        notify_boundary('next', 'quickfix')
      end
    elseif not vim.tbl_isempty(vim.fn.getloclist(0)) then
      local ok, _ = pcall(function() vim.cmd('lnext') end)
      if not ok then
        notify_boundary('next', 'location')
      end
    else
      vim.notify("QuickToggle: No quickfix or location list to navigate.", vim.log.levels.INFO)
    end
  end
end

--- 前の項目に移動
function M.previous_item()
  local list_type = get_active_list_type()

  if list_type == 'quickfix' then
    local ok, _ = pcall(function() vim.cmd('cprevious') end)
    if not ok then
      notify_boundary('previous', 'quickfix')
    end
  elseif list_type == 'location' then
    local ok, _ = pcall(function() vim.cmd('lprevious') end)
    if not ok then
      notify_boundary('previous', 'location')
    end
  else
    if not vim.tbl_isempty(vim.fn.getqflist()) then
      local ok, _ = pcall(function() vim.cmd('cprevious') end)
      if not ok then
        notify_boundary('previous', 'quickfix')
      end
    elseif not vim.tbl_isempty(vim.fn.getloclist(0)) then
      local ok, _ = pcall(function() vim.cmd('lprevious') end)
      if not ok then
        notify_boundary('previous', 'location')
      end
    else
      vim.notify("QuickToggle: No quickfix or location list to navigate.", vim.log.levels.INFO)
    end
  end
end

return M
