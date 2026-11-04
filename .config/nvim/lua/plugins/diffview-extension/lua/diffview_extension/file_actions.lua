local M = {}

function M.open_directory()
  local view = require('diffview.lib').get_current_view()
  if not view or not view.panel then return end

  local file
  if view.panel:is_focused() then
    file = view.panel:get_item_at_cursor()
    if file and file.single_file then file = view:infer_cur_file() end
  else
    file = view.cur_entry or (type(view.cur_file) == 'function' and view:cur_file())
  end
  -- Native file entries carry worktree paths even for historical buffers.
  -- Headers, directory rows and the extension's PR rows are not file entries.
  if not file or type(file.absolute_path) ~= 'string' then return end
  local directory = vim.fs.dirname(file.absolute_path)
  if vim.fn.isdirectory(directory) ~= 1 then
    vim.notify('Directory does not exist in the working tree: ' .. directory, vim.log.levels.WARN)
    return
  end

  local oil = require('oil')
  vim.cmd.tabnew()
  oil.open(directory)
end

return M
