local M = {}

local active = {}

local DEFAULTS = {
  enabled = false,
  duration_ms = 140,
  step_ms = 10,
  max_delta = 80,
}

local function in_cmdline_mode()
  local ok, mode = pcall(vim.api.nvim_get_mode)
  local current_mode = ok and mode and mode.mode or ""
  return type(current_mode) == "string" and current_mode:sub(1, 1) == "c"
end

local function positive_integer(value, fallback)
  local number = tonumber(value)
  if not number or number <= 0 then
    return fallback
  end
  return math.floor(number)
end

function M.config(value)
  local cfg = vim.tbl_extend("force", DEFAULTS, type(value) == "table" and value or {})
  if value == true then
    cfg.enabled = true
  end
  if cfg.enabled ~= true then
    return nil
  end
  cfg.duration_ms = positive_integer(cfg.duration_ms, DEFAULTS.duration_ms)
  cfg.step_ms = positive_integer(cfg.step_ms, DEFAULTS.step_ms)
  cfg.max_delta = positive_integer(cfg.max_delta, DEFAULTS.max_delta)
  return cfg
end

local function close_timer(entry)
  if type(entry) ~= "table" then
    return
  end
  if entry.timer then
    local timer = entry.timer
    entry.timer = nil
    pcall(function() timer:stop() end)
    pcall(function() timer:close() end)
  end
end

local function close_entry(key)
  local entry = active[key]
  if not entry then
    return
  end
  active[key] = nil
  close_timer(entry)
end

function M.stop_window(win)
  close_entry(tostring(win or ""))
end

function M.stop_for_buffer(bufnr)
  if not bufnr then
    return
  end
  for key, entry in pairs(active) do
    if entry.bufnr == bufnr then
      close_entry(key)
    end
  end
end

function M.active(win)
  local entry = active[tostring(win or "")]
  return entry ~= nil
end

local function normal_scroll(win, key, amount)
  if not win or not vim.api.nvim_win_is_valid(win) or amount <= 0 then
    return false
  end

  local moved = false
  pcall(vim.api.nvim_win_call, win, function()
    local before = vim.fn.winsaveview()
    local termcode = vim.api.nvim_replace_termcodes(key, true, false, true)
    vim.cmd.normal({ bang = true, args = { tostring(amount) .. termcode } })
    local after = vim.fn.winsaveview()
    moved = before.topline ~= after.topline or before.lnum ~= after.lnum or before.topfill ~= after.topfill
  end)
  return moved
end

function M.scroll_by_lines(win, delta, cfg, opts)
  opts = opts or {}
  cfg = M.config(cfg)
  if not cfg then
    return false
  end
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end

  local amount = math.floor(math.abs(tonumber(delta) or 0))
  if amount <= 0 then
    return false
  end

  local bufnr = opts.bufnr or vim.api.nvim_win_get_buf(win)
  local direction = delta > 0 and 1 or -1
  local key = direction > 0 and "<C-e>" or "<C-y>"
  local max_delta = positive_integer(cfg.max_delta, DEFAULTS.max_delta)
  local on_finish = opts.on_finish

  close_entry(tostring(win))

  -- A manual animation can overlap entering command-line mode. Stop before its
  -- next nvim_win_call(), which would invalidate command-line completion state.
  if in_cmdline_mode() then
    return false
  end

  if amount > max_delta then
    local moved = normal_scroll(win, key, amount)
    if type(on_finish) == "function" then
      vim.schedule(function()
        on_finish(moved)
      end)
    end
    return moved
  end

  local uv = vim.uv or vim.loop
  if not uv or not uv.new_timer then
    local moved = normal_scroll(win, key, amount)
    if type(on_finish) == "function" then
      vim.schedule(function()
        on_finish(moved)
      end)
    end
    return moved
  end

  local timer = uv.new_timer()
  if not timer then
    return false
  end

  local key_name = tostring(win)
  local duration_ms = positive_integer(cfg.duration_ms, DEFAULTS.duration_ms)
  local step_ms = positive_integer(cfg.step_ms, DEFAULTS.step_ms)
  local frames = math.max(1, math.min(amount, math.floor(duration_ms / step_ms)))
  local frame = 0
  local moved_total = 0
  local any_moved = false

  local entry = {
    timer = timer,
    bufnr = bufnr,
  }
  active[key_name] = entry

  local function finish()
    if active[key_name] ~= entry then
      close_timer(entry)
      return
    end
    active[key_name] = nil
    close_timer(entry)
    if type(on_finish) == "function" then
      on_finish(any_moved)
    end
  end

  timer:start(0, step_ms, vim.schedule_wrap(function()
    if active[key_name] ~= entry then
      close_timer(entry)
      return
    end
    if not vim.api.nvim_win_is_valid(win) then
      finish()
      return
    end
    if bufnr and vim.api.nvim_win_get_buf(win) ~= bufnr then
      finish()
      return
    end
    if in_cmdline_mode() then
      finish()
      return
    end

    frame = frame + 1
    local progress = math.min(1, frame / frames)
    local eased = 1 - ((1 - progress) * (1 - progress) * (1 - progress))
    local target = math.min(amount, math.max(moved_total + 1, math.floor(amount * eased)))
    local step_amount = target - moved_total
    if step_amount <= 0 then
      return
    end

    local moved = normal_scroll(win, key, step_amount)
    if moved then
      any_moved = true
    end
    moved_total = target

    if not moved or moved_total >= amount or frame >= frames then
      finish()
    end
  end))

  return true
end

return M
