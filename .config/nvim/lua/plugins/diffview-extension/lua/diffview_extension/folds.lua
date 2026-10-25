-- Preserve a closed fold heading when returning to the same native diff buffer.
local M = {}
local api = vim.api

function M.attach(view)
  if not view or view._closed_fold_cursor_hooked or type(view.snapshot_main_view) ~= 'function'
    or type(view.restore_main_view) ~= 'function' then return end
  view._closed_fold_cursor_hooked = true
  -- Tie intent to the exact one-shot snapshot, without persisting buffer-local
  -- fold coordinates in Diffview sessions or retaining replaced snapshots.
  local closed = setmetatable({}, { __mode = 'k' })
  local snapshot, restore = view.snapshot_main_view, view.restore_main_view
  view.snapshot_main_view = function(self, path, alias)
    snapshot(self, path, alias)
    local target = self.cursor_map[path]
    local main = self.cur_layout and self.cur_layout:get_main_win()
    if not target or not main or not main.id or not api.nvim_win_is_valid(main.id) then return end
    api.nvim_win_call(main.id, function()
      local row = target.winview.lnum
      if vim.wo.diff and vim.wo.foldmethod == 'diff' and vim.fn.foldclosed(row) == row then
        closed[target] = { row = row, tick = api.nvim_buf_get_changedtick(0) }
      end
    end)
  end
  view.restore_main_view = function(self, path)
    local target = self.cursor_map[path]
    local fold = target and closed[target]
    local carried = self:has_carry_lnum(self.cur_entry)
    local restored = restore(self, path)
    if not restored or not fold or carried then return restored end
    local main = self.cur_layout and self.cur_layout:get_main_win()
    if not main or not main.id or not api.nvim_win_is_valid(main.id) then return restored end
    local buf = api.nvim_win_get_buf(main.id)
    -- A line translated into another revision, or an edited buffer, should
    -- still be revealed by upstream. Only an unchanged snapshot has the same
    -- closed heading, buffer identity and fold coordinates.
    if buf ~= target.bufnr or api.nvim_buf_get_name(buf) ~= target.bufname
      or api.nvim_buf_get_changedtick(buf) ~= fold.tick then return restored end
    api.nvim_win_call(main.id, function()
      if vim.wo.diff and vim.wo.foldmethod == 'diff' and vim.wo.foldenable
        and api.nvim_win_get_cursor(0)[1] == fold.row and vim.fn.foldlevel(fold.row) > 0 then
        -- Upstream's restore runs zv unconditionally. Reclose before redraw,
        -- then restore the viewport captured while this fold was closed.
        if vim.fn.foldclosed(fold.row) == -1 then vim.cmd('silent! keepjumps normal! zc') end
        vim.fn.winrestview(target.winview)
      end
    end)
    return restored
  end
end

function M.setup(group)
  api.nvim_create_autocmd('User', { group = group,
    pattern = { 'DiffviewViewOpened', 'DiffviewViewEnter', 'DiffviewDiffBufWinEnter' },
    callback = function()
      local lib = package.loaded['diffview.lib']
      if lib then M.attach(lib.get_current_view()) end
    end,
  })
end

return M
