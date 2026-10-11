local M = {}
function M.new(f)
  local view, async = require('git.features.pr'), require('git.features.async')
  local ui = {}
  function ui.wait(predicate)
    assert(vim.wait(5000, predicate, 10), table.concat(f.notifications, '\n'))
  end
  function ui.loaded()
    ui.wait(function() return ui.buf and view.model(ui.buf) and not async.busy(f.root) end)
  end
  function ui.open()
    ui.buf = assert(view.open({ root = f.root, url = f.pr.url })); ui.loaded()
    return ui.buf
  end
  function ui.source()
    local win = vim.fn.bufwinid(ui.buf)
    assert(win ~= -1)
    vim.api.nvim_set_current_win(win)
  end
  function ui.row(value)
    for i, line in ipairs(vim.api.nvim_buf_get_lines(ui.buf, 0, -1, false)) do
      if line:find(value, 1, true) then return i end
    end
    error('Missing PR row: ' .. value)
  end
  function ui.key(key, row)
    if row then ui.source(); vim.api.nvim_win_set_cursor(0, { row, 0 }) end
    local map = vim.fn.maparg(key, 'n', false, true)
    assert(map.callback, 'Missing mapping: ' .. key)
    return map.callback()
  end
  function ui.menu(key)
    ui.source(); ui.key(key)
    ui.wait(function() return vim.bo.filetype == 'gitactionmenu' end)
  end
  function ui.body(lines)
    assert(vim.bo.filetype == 'markdown')
    local first = vim.api.nvim_win_get_cursor(0)[1] - 1
    vim.api.nvim_buf_set_lines(0, first, -1, false, lines)
    return vim.api.nvim_get_current_buf()
  end
  function ui.send(buf)
    vim.api.nvim_buf_call(buf, function() vim.cmd('write') end)
    ui.wait(function() return not vim.api.nvim_buf_is_valid(buf) end)
    ui.loaded()
  end
  function ui.failed(buf, substring)
    local start = #f.notifications
    vim.api.nvim_buf_call(buf, function() vim.cmd('write') end)
    ui.wait(function()
      for i = start + 1, #f.notifications do if f.notifications[i]:find(substring, 1, true) then return true end end
    end)
    assert(vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modifiable, 'Failed request lost the editable draft')
  end
  function ui.refresh()
    local old = view.model(ui.buf)
    view.refresh(ui.buf)
    ui.wait(function() return view.model(ui.buf) ~= old and not async.busy(f.root) end)
  end
  function ui.expand_files()
    ui.source(); ui.key('>', ui.row('Changes ('))
    local first, last
    for row = 1, vim.api.nvim_buf_line_count(ui.buf) do
      local _, info = view.entry_at(ui.buf, row)
      if info and info.header then first, last = first or row, row end
    end
    if not first then return end
    vim.api.nvim_win_set_cursor(0, { first, 0 }); vim.cmd('normal! V')
    vim.api.nvim_win_set_cursor(0, { last, 0 })
    vim.fn.maparg('>', 'x', false, true).callback()
  end
  function ui.close_draft(buf) vim.api.nvim_buf_delete(buf, { force = true }) end
  return ui
end
return M
