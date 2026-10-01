local HarpoonGroup = require('harpoon.autocmd')
local ns = vim.api.nvim_create_namespace('HarpoonIconNS')
local items = require('plugins.harpoon_items')
local M = {}
local defaults = { icon = '󰛢', nearest_entry = true, icon_position = 'eol' }
local active_config = defaults

function M.set_buffer_icon(config, buf)
  config, buf = config or active_config, buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) then return end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if config.icon_position == 'signcolumn' then vim.fn.sign_unplace('HarpoonGroup', { buffer = buf }) end
  local list = require('harpoon'):list('multiple')
  for index = 1, list:length() do
    local item = list:get(index)
    -- Panel rows are dynamic. The menu marks their surface; file signs track lines.
    if item and not item.context.git and items.matches(item, buf) then
      local row = math.max(1, math.min(item.context.row or 1, vim.api.nvim_buf_line_count(buf)))
      if config.icon_position == 'signcolumn' then
        vim.fn.sign_define('HarpoonIcon', { text = config.icon, texthl = 'DevIconQt' })
        vim.fn.sign_place(0, 'HarpoonGroup', 'HarpoonIcon', buf, { lnum = row })
      else
        vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, { virt_text = { { config.icon, 'DevIconQt' } },
          virt_text_pos = config.icon_position, right_gravity = false })
      end
    end
  end
end
function M.set_current_buffer_icon(cx, config)
  local source = items.source
  if not source then return end
  local nearest, distance
  for row = 1, #cx.contents do
    local item = items.menu_item(cx.bufnr, row)
    if item and items.same_surface(item, source) then
      vim.api.nvim_buf_set_extmark(cx.bufnr, ns, row - 1, 0,
        { virt_text = { { config.icon, 'DevIconQt' } }, virt_text_pos = 'eol' })
      local d = math.abs((source.context.row or 1) - (item.context.row or 1))
      if items.equals(item, source) then d = -1 end
      if not distance or d < distance then nearest, distance = row, d end
    end
  end
  if nearest and config.nearest_entry then vim.api.nvim_win_set_cursor(cx.win_id, { nearest, 0 }) end
end
function M.setup(user_config)
  active_config = vim.tbl_deep_extend('force', {}, defaults, user_config or {})
  local timers = {}
  vim.api.nvim_create_autocmd({ 'BufEnter', 'BufWritePost' }, { group = HarpoonGroup,
    callback = function(ev) M.set_buffer_icon(active_config, ev.buf) end })
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'InsertLeave' }, { group = HarpoonGroup,
    callback = function(ev)
      if vim.bo[ev.buf].buftype ~= '' then return end
      if timers[ev.buf] then vim.fn.timer_stop(timers[ev.buf]) end
      timers[ev.buf] = vim.fn.timer_start(100, function()
        vim.schedule(function() M.set_buffer_icon(active_config, ev.buf); timers[ev.buf] = nil end)
      end)
    end })
  require('harpoon'):extend({
    ADD = function() M.set_buffer_icon() end,
    REMOVE = function(obj)
      local reordered = {}
      for index = 1, obj.list:length() do
        local item = obj.list:get(index)
        if item then reordered[#reordered + 1] = item end
      end
      obj.list.items, obj.list._length = reordered, #reordered
      M.set_buffer_icon()
    end,
    UI_CREATE = function(obj) M.set_current_buffer_icon(obj, active_config) end,
  })
  M.set_buffer_icon()
end
return M
