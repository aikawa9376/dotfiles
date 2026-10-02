local M = {}

function M.capture()
  local snapshot = {
    buffers = 0, loaded_buffers = 0, terminals = 0, autocmds = #vim.api.nvim_get_autocmds({}),
    processes = 0, timers = 0, watchers = 0, handles = {},
    rss_bytes = vim.uv.resident_set_memory(), lua_kib = collectgarbage('count'), autocmd_groups = {},
  }
  for _, autocmd in ipairs(vim.api.nvim_get_autocmds({})) do
    local group = autocmd.group_name or 'ungrouped'
    snapshot.autocmd_groups[group] = (snapshot.autocmd_groups[group] or 0) + 1
  end
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buffer) then
      snapshot.buffers = snapshot.buffers + 1
      if vim.api.nvim_buf_is_loaded(buffer) then
        snapshot.loaded_buffers = snapshot.loaded_buffers + 1
        if vim.bo[buffer].buftype == 'terminal' then snapshot.terminals = snapshot.terminals + 1 end
      end
    end
  end
  vim.uv.walk(function(handle)
    if handle:is_closing() then return end
    local kind = handle:get_type()
    local count = snapshot.handles[kind] or { total = 0, active = 0 }
    count.total = count.total + 1
    if handle:is_active() then count.active = count.active + 1 end
    snapshot.handles[kind] = count
  end)
  snapshot.processes = (snapshot.handles.process or {}).total or 0
  snapshot.timers = (snapshot.handles.timer or {}).total or 0
  snapshot.watchers = (snapshot.handles.fs_event or {}).total or 0
  return snapshot
end

return M
