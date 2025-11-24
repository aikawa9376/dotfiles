local M = {}
local window = require("lazyagent.window")
local state = require("logic.state")

if not vim.g.lazyagent_scratch_deprecation_shown then
  vim.schedule(function()
    vim.notify("lazyagent.scratch is deprecated and will be removed in a future version; use lazyagent.window or LazyAgentToggle instead", vim.log.levels.INFO)
  end)
  vim.g.lazyagent_scratch_deprecation_shown = true
end

-- Compatibility layer: keep a minimal API that forwards to the new window-based
-- approach. This preserves callers that still require the old `scratch` module.
local bufnr_in = nil

-- Creates and returns a buffer to be used by window.open()
local function ensure_buffer(opts)
  opts = opts or {}
  local filetype = opts.filetype or "lazyagent"
  local initial_content = opts.initial_content
  local source_bufnr = opts.source_bufnr

  if not bufnr_in or not vim.api.nvim_buf_is_valid(bufnr_in) then
    bufnr_in = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr_in].bufhidden = "wipe"
    vim.bo[bufnr_in].buflisted = false
    vim.bo[bufnr_in].modifiable = true
    vim.bo[bufnr_in].buftype = "nofile"
    vim.bo[bufnr_in].filetype = filetype
  end

  if source_bufnr and source_bufnr > 0 then
    pcall(function() vim.b[bufnr_in].lazyagent_source_bufnr = source_bufnr end)
  end

  if initial_content then
    if type(initial_content) == "string" then
      initial_content = vim.split(initial_content, "\n")
    end
    if type(initial_content) == "table" and #initial_content > 0 then
      vim.api.nvim_buf_set_lines(bufnr_in, 0, -1, false, initial_content)
    end
  end

    -- Attach cache saving for scratch buffers (if the main module provides it).
    pcall(function()
      local sa = require("lazyagent")
      if sa and sa.attach_cache_to_buf then
        sa.attach_cache_to_buf(bufnr_in)
      end
    end)

  return bufnr_in
end

function M.open(opts)
  opts = opts or {}
  local filetype = opts.filetype or "lazyagent"
  local initial_content = opts.initial_content or {}
  local bufnr = ensure_buffer({ filetype = filetype, initial_content = initial_content, source_bufnr = opts.source_bufnr })
  local open_opts = { window_type = opts.window_type or "float" }
  if opts.start_in_insert_on_focus ~= nil then
    open_opts.start_in_insert_on_focus = opts.start_in_insert_on_focus
  else
    open_opts.start_in_insert_on_focus = (state.opts and state.opts.start_in_insert_on_focus) or false
  end
  window.open(bufnr, open_opts)

  -- Register buffer-local scratch keymaps so standalone scratch buffers also get
  -- the default key bindings (no tmux pane).
    pcall(function()
      local sa = require("lazyagent")
      if sa and sa.register_scratch_keymaps then
        sa.register_scratch_keymaps(bufnr, { scratch_keymaps = opts.scratch_keymaps, source_bufnr = opts.source_bufnr })
      end
    end)
end

function M.open_output(_)
  -- No-op: results are shown in tmux pane.
end

function M.append_output(_)
  -- No-op for compatibility
end

function M.clear_output()
  -- No-op
end

function M.is_open()
  return window.is_open()
end

function M.get_bufnr()
  return window.get_bufnr()
end

function M.get_output_bufnr()
  return nil
end

function M.close()
  if bufnr_in and vim.api.nvim_buf_is_valid(bufnr_in) then
    vim.api.nvim_buf_delete(bufnr_in, { force = true })
  end
  bufnr_in = nil
  window.close()
end

return M
