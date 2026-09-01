local M = {}

local state = require("lazyagent.logic.state")
local window = require("lazyagent.window")

local contexts = {}

local function resolved_keymaps(overrides)
  return vim.tbl_deep_extend(
    "force",
    {},
    (state.opts and state.opts.scratch_keymaps) or {},
    overrides or {}
  )
end

local function register_keymap(bufnr, mode, lhs, callback, opts)
  if type(lhs) ~= "string" or lhs == "" then return end
  vim.keymap.set(mode, lhs, callback, vim.tbl_extend("force", {
    buffer = bufnr,
    noremap = true,
    silent = true,
  }, opts or {}))
end

local function register_input_keymaps(bufnr, opts)
  local keys = resolved_keymaps(opts.scratch_keymaps)
  local submit = function() M.submit(bufnr) end
  local submit_desc = opts.submit_desc or "Submit LazyAgent input"
  local normal_submit = keys.send_key_normal or "<CR>"
  local insert_submit = keys.send_key_insert or "<C-s>"
  local send_and_clear = keys.send_and_clear or "<C-Space>"

  register_keymap(bufnr, "n", normal_submit, submit, { desc = submit_desc })
  if insert_submit ~= normal_submit then
    register_keymap(bufnr, "n", insert_submit, submit, { desc = submit_desc })
  end
  register_keymap(bufnr, "i", insert_submit, submit, { desc = submit_desc })
  if send_and_clear ~= normal_submit and send_and_clear ~= insert_submit then
    register_keymap(bufnr, "n", send_and_clear, submit, { desc = submit_desc })
  end
  if send_and_clear ~= insert_submit then
    register_keymap(bufnr, "i", send_and_clear, submit, { desc = submit_desc })
  end
  register_keymap(bufnr, "n", keys.close or "q", function() M.close(bufnr) end, {
    nowait = true,
    desc = opts.cancel_desc or "Cancel LazyAgent input",
  })
end

local function close_buffer(bufnr)
  if window.get_bufnr() == bufnr then
    window.close({ force = true })
  else
    local winid = vim.fn.bufwinid(bufnr)
    if winid ~= -1 and vim.api.nvim_win_is_valid(winid) then
      pcall(vim.api.nvim_win_close, winid, true)
    end
  end
  if vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
end

local function finish(bufnr, reason)
  local ctx = contexts[bufnr]
  if not ctx or ctx.closed then return end
  ctx.closed = true
  contexts[bufnr] = nil
  if type(ctx.on_close) == "function" then pcall(ctx.on_close, reason, bufnr) end
end

function M.close(bufnr)
  if not contexts[bufnr] then return false end
  finish(bufnr, "cancel")
  close_buffer(bufnr)
  return true
end

function M.submit(bufnr)
  local ctx = contexts[bufnr]
  if not ctx or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil, "Scratch input is no longer valid"
  end
  local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  if ctx.trim ~= false then text = vim.trim(text) end
  if ctx.require_text ~= false and text == "" then
    local err = ctx.empty_message or "Input is empty"
    vim.notify((ctx.error_prefix or "LazyAgent: ") .. err, vim.log.levels.ERROR)
    return nil, err
  end
  local result, err = ctx.on_submit(text, bufnr)
  if not result then
    vim.notify((ctx.error_prefix or "LazyAgent: ") .. tostring(err), vim.log.levels.ERROR)
    return nil, err
  end
  finish(bufnr, "submit")
  pcall(vim.cmd, "stopinsert")
  close_buffer(bufnr)
  return result
end

function M.open(opts)
  opts = opts or {}
  assert(type(opts.on_submit) == "function", "scratch input requires on_submit")

  local source_bufnr = opts.source_bufnr or vim.api.nvim_get_current_buf()
  local source_winid = opts.source_winid or vim.api.nvim_get_current_win()
  local bufnr = window.create_scratch_buffer({
    filetype = opts.filetype or "markdown",
    source_bufnr = source_bufnr,
    source_winid = source_winid,
  })
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(tostring(opts.text or ""), "\n", { plain = true }))
  for name, value in pairs(opts.buffer_vars or {}) do vim.b[bufnr][name] = value end

  contexts[bufnr] = {
    empty_message = opts.empty_message,
    error_prefix = opts.error_prefix,
    on_close = opts.on_close,
    on_submit = opts.on_submit,
    require_text = opts.require_text,
    trim = opts.trim,
  }
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    once = true,
    callback = function() finish(bufnr, "wipeout") end,
  })

  local global_opts = state.opts or {}
  local start_in_insert = opts.start_in_insert_on_focus
  if start_in_insert == nil then start_in_insert = global_opts.start_in_insert_on_focus == true end
  local is_vertical = opts.is_vertical
  if is_vertical == nil then is_vertical = true end
  local winid = window.open(bufnr, {
    window_type = opts.window_type or global_opts.window_type or "float",
    start_in_insert_on_focus = start_in_insert,
    is_vertical = is_vertical,
    parent_winid = source_winid,
    source_winid = source_winid,
    window_opts = opts.window_opts,
    title = opts.title or " LazyAgent Input ",
    close_on_focus_lost = false,
  }) or window.get_winid()

  if winid and vim.api.nvim_win_is_valid(winid) then
    vim.wo[winid].linebreak = true
  end
  register_input_keymaps(bufnr, opts)
  return bufnr, winid
end

return M
