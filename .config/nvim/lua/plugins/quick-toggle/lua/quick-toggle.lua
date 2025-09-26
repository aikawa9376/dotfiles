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

--- Quickfix/Locationリストを賢くトグルする関数
function M.toggle()
  local qf_win_id = get_qf_win_id()

  if qf_win_id then
    local win_info = vim.fn.getwininfo(qf_win_id)[1]
    if win_info and win_info.loclist == 1 then
      vim.cmd('lclose')
    else
      vim.cmd('cclose')
    end
  else
    if not vim.tbl_isempty(vim.fn.getqflist()) then
      vim.cmd('copen')
    elseif not vim.tbl_isempty(vim.fn.getloclist(0)) then
      vim.cmd('lopen')
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
  if not vim.tbl_isempty(vim.fn.getloclist(0)) then
    local ok, _ = pcall(function() vim.cmd('lnext') end)
    if not ok then
      notify_boundary('next', 'location')
    end
  elseif not vim.tbl_isempty(vim.fn.getqflist()) then
    local ok, _ = pcall(function() vim.cmd('cnext') end)
    if not ok then
      notify_boundary('next', 'quickfix')
    end
  else
    vim.notify("QuickToggle: No quickfix or location list to navigate.", vim.log.levels.INFO)
  end
end

--- 前の項目に移動
function M.previous_item()
  if not vim.tbl_isempty(vim.fn.getloclist(0)) then
    local ok, _ = pcall(function() vim.cmd('lprevious') end)
    if not ok then
      notify_boundary('previous', 'location')
    end
  elseif not vim.tbl_isempty(vim.fn.getqflist()) then
    local ok, _ = pcall(function() vim.cmd('cprevious') end)
    if not ok then
      notify_boundary('previous', 'quickfix')
    end
  else
    vim.notify("QuickToggle: No quickfix or location list to navigate.", vim.log.levels.INFO)
  end
end

return M
