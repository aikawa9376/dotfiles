-- Background Branch refreshes keep their last complete snapshot until publish.
local M = {}
local utils = require('git.utils')

function M.attach(buf, group, opts)
  local active, dirty, generation = true, false, 0
  local timer, task, from_menu
  local start, queue
  local function live() return active and utils.is_valid_buf(buf) end
  local function stop_timer()
    if timer then timer:stop(); timer:close(); timer = nil end
  end
  local function invalidate()
    generation = generation + 1
    if task then task.cancel(); task = nil end
  end
  local controller = {}
  function controller.clear()
    stop_timer(); invalidate(); dirty = false
  end
  function controller.stop()
    if not active then return end
    active = false; controller.clear()
    if opts.on_stop then opts.on_stop() end
  end
  start = function()
    stop_timer()
    if not live() or not utils.is_buf_visible(buf) then return end
    dirty = false
    local current = generation
    local function complete(ok, snapshot)
      if not live() or generation ~= current then return end
      task = nil
      if not utils.is_buf_visible(buf) then dirty = true; return end
      if not ok then
        dirty = true
        vim.notify('Branch refresh failed: ' .. tostring(snapshot), vim.log.levels.WARN)
        return
      end
      opts.publish(snapshot)
    end
    local ok, job, err = pcall(opts.load, complete)
    if not ok then complete(false, job)
    elseif not job then complete(false, err or 'Could not start background read')
    else task = job end
  end
  queue = function()
    if not live() or timer or not utils.is_buf_visible(buf) then return end
    local pending = vim.uv.new_timer()
    timer = pending
    pending:start(150, 0, vim.schedule_wrap(function()
      if timer == pending then start() end
    end))
  end
  vim.api.nvim_create_autocmd('BufLeave', { group = group, callback = function(ev)
    from_menu = vim.bo[ev.buf].filetype == 'gitactionmenu'
      and vim.b[ev.buf].git_action_menu_source == buf
  end })
  vim.api.nvim_create_autocmd('BufEnter', { group = group, buffer = buf, callback = function()
    if opts.opening and opts.opening() then return end
    if from_menu then
      if dirty then queue() end
      return
    end
    invalidate(); dirty = true; start()
  end })
  vim.api.nvim_create_autocmd('User', { group = group, pattern = 'GitChanged', callback = function(ev)
    local root = ev.data and ev.data.work_tree
    if not live() or (root and utils.normalize_path(root) ~= opts.root) then return end
    invalidate(); dirty = true; queue()
  end })
  vim.api.nvim_create_autocmd({ 'BufUnload', 'BufWipeout' }, {
    group = group, buffer = buf, once = true, callback = controller.stop,
  })
  vim.api.nvim_create_autocmd('BufWipeout', { group = group, buffer = buf, once = true, callback = function()
    pcall(vim.api.nvim_del_augroup_by_id, group)
  end })
  return controller
end

return M
