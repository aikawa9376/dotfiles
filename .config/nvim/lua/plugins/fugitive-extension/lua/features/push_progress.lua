local M = {}
local utils = require('fugitive_utils')
local namespace = vim.api.nvim_create_namespace('fugitive_push_progress')
local active = {}
local frames = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }
local frame = 1
local timer

function M.render(bufnr)
  if not vim.api.nvim_buf_is_loaded(bufnr) then return end
  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  local root = utils.get_buf_work_tree(bufnr)
  if not root or not active[utils.normalize_path(root)] then return end
  for row, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if line:match('^Unpushed %[only%] %(%d+%)$') or line:match('^Commits %[latest 15%+%] %(%d+%)$') then
      vim.api.nvim_buf_set_extmark(bufnr, namespace, row - 1, 0, {
        virt_text = { { ' ' .. frames[frame] .. ' Pushing…', 'DiagnosticInfo' } },
        virt_text_pos = 'eol',
      })
      return
    end
  end
end

local function render_all()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].filetype == 'fugitivestatus' then
      M.render(bufnr)
    end
  end
end

-- Return an idempotent completion callback, including for failed job starts.
function M.start(work_tree)
  local root = utils.normalize_path(work_tree)
  active[root] = (active[root] or 0) + 1
  render_all()
  if not timer then
    timer = vim.uv.new_timer()
    timer:start(100, 100, vim.schedule_wrap(function()
      if not next(active) then return end
      frame = frame % #frames + 1
      render_all()
    end))
  end
  local finished = false
  return function()
    if finished then return end
    finished = true
    active[root] = active[root] > 1 and active[root] - 1 or nil
    if not next(active) and timer then
      timer:stop()
      timer:close()
      timer = nil
    end
    render_all()
  end
end

return M
