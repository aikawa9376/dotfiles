local M = {}
local DEFAULT_SUBMIT_DELAY_MS = 600
local DEFAULT_SUBMIT_RETRY = 1
local util = require("lazyagent.util")

-- Minimal builtin backend implementation using Neovim terminals/buffers:
-- pane_id will be represented as the buffer number string for terminal buffers,
-- and backend functions accept pane_id as a string or number.

local function to_bufnum(pane_id)
  if not pane_id then return nil end
  local n = tonumber(pane_id)
  if n then return n end
  return pane_id
end

local function term_job_for_buf(bufnr)
  if not bufnr then return nil end
  if vim.api.nvim_buf_is_valid(bufnr) and vim.b[bufnr] and vim.b[bufnr].terminal_job_id then
    return vim.b[bufnr].terminal_job_id
  end
  return nil
end

function M.split(command, size, is_vertical, on_split)
  if is_vertical then
    vim.cmd("vsplit")
  else
    vim.cmd("split")
  end
  local win = vim.api.nvim_get_current_win()
  -- Try to apply percent dimension if provided
  if type(size) == "number" and size > 0 then
    if is_vertical then
      local width = math.max(10, math.floor((vim.o.columns * size) / 100))
      pcall(vim.api.nvim_win_set_width, win, width)
    else
      local height = math.max(3, math.floor((vim.o.lines * size) / 100))
      pcall(vim.api.nvim_win_set_height, win, height)
    end
  end

  -- Open a terminal in the current window (cmd must be a string or nil)
  local cmd = command or vim.o.shell or "/bin/sh"
  pcall(function() vim.cmd("terminal " .. vim.fn.shellescape(cmd)) end)
  local bufnr = vim.api.nvim_get_current_buf()
  -- Wait briefly for termopen to set the buffer's terminal job id; this avoids race
  -- conditions where consumers try to `chansend` before job id exists.
  local max_tries = 20
  local tries = 0
  local delay_ms = 30
  local function call_on_split()
    if on_split then vim.schedule_wrap(on_split)(tostring(bufnr)) end
  end
  local function check_job_ready()
    local jobid = term_job_for_buf(bufnr)
    if jobid or tries >= max_tries then
      -- Either the job is ready, or we've reached the retry limit - call the callback.
      call_on_split()
      return
    end
    tries = tries + 1
    vim.defer_fn(check_job_ready, delay_ms)
  end
  check_job_ready()
end

function M.pane_exists(pane_id)
  local bufnr = to_bufnum(pane_id)
  if not bufnr then return false end
  return vim.api.nvim_buf_is_valid(bufnr)
end

function M.send_keys(target_pane, keys)
  local bufnr = to_bufnum(target_pane)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  local jobid = term_job_for_buf(bufnr)
  if jobid then
    local s = ""
    if type(keys) == "table" then
      for _,k in ipairs(keys) do s = s .. tostring(k) end
    else
      s = tostring(keys or "")
    end
    pcall(vim.fn.chansend, jobid, s)
    return true
  end
  -- Not a terminal: just append the keys to the buffer
  if vim.api.nvim_buf_is_valid(bufnr) then
    local lines = vim.split(util.normalize_text(tostring(keys or "")), "\n")
    local last = math.max(0, vim.api.nvim_buf_line_count(bufnr))
    pcall(vim.api.nvim_buf_set_lines, bufnr, last, last, false, lines)
    return true
  end
  return false
end

function M.kill_pane(target_pane)
  local bufnr = to_bufnum(target_pane)
  if not bufnr then return end
  if vim.api.nvim_buf_is_valid(bufnr) then
    local wins = vim.fn.win_findbuf(bufnr)
    if wins and #wins > 0 then
      for _, w in ipairs(wins) do
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
end

function M.copy_mode(target_pane)
  -- Not implemented for builtin; fallback no-op.
end

function M.scroll_up(target_pane)
  local bufnr = to_bufnum(target_pane)
  local jobid = term_job_for_buf(bufnr)
  if jobid then
    -- Try to send PageUp as an escape sequence; this will not always match a program
    pcall(vim.fn.chansend, jobid, "\027[5~")
  end
end

function M.scroll_down(target_pane)
  local bufnr = to_bufnum(target_pane)
  local jobid = term_job_for_buf(bufnr)
  if jobid then
    pcall(vim.fn.chansend, jobid, "\027[6~")
  end
end

function M.set_buffer(text, on_done, opts)
  -- Implement a simple write-to-temp file for set_buffer to match tmux.load-buffer semantics.
  local tmpfile = vim.fn.tempname()
  local f = assert(io.open(tmpfile, "wb"))
  f:write(util.normalize_text(text))
  f:close()
  if on_done then vim.schedule(on_done) end
end

function M.paste(target_pane, opts)
  opts = opts or {}
  local bufnr = to_bufnum(target_pane)
  local text = opts and opts.text or ""
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return false end

  local jobid = term_job_for_buf(bufnr)
  if jobid then
    pcall(vim.fn.chansend, jobid, util.normalize_text(text))
    if opts and opts.on_done then vim.schedule_wrap(opts.on_done)(true) end
    return true
  else
    local lines = vim.split(util.normalize_text(text), "\n")
    local last = math.max(0, vim.api.nvim_buf_line_count(bufnr))
    pcall(vim.api.nvim_buf_set_lines, bufnr, last, last, false, lines)
    if opts and opts.on_done then vim.schedule_wrap(opts.on_done)(true) end
    return true
  end
end

function M.paste_and_submit(target_pane, text, submit_keys, opts)
  opts = opts or {}
  submit_keys = submit_keys or { "C-m" }
  local submit_delay = opts.submit_delay or DEFAULT_SUBMIT_DELAY_MS
  local submit_retry = opts.submit_retry or DEFAULT_SUBMIT_RETRY
  local move_to_end = opts.move_to_end or false
  local use_bracketed_paste = opts.use_bracketed_paste or false

  local normalized_text = util.normalize_text(text)
  local bufnr = to_bufnum(target_pane)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return false end

  local jobid = term_job_for_buf(bufnr)
  if jobid then
    local esc = string.char(27)
    -- Move to end of current line/input prior to paste when requested
    if move_to_end then
      -- ASCII Ctrl-E (0x05) is commonly used to move to end in shells/readline
      pcall(vim.fn.chansend, jobid, string.char(5))
    end

    -- Wrap with bracketed paste sequences if requested.
    if use_bracketed_paste then
      pcall(vim.fn.chansend, jobid, esc .. "[200~")
    end

    pcall(vim.fn.chansend, jobid, normalized_text)

    if use_bracketed_paste then
      pcall(vim.fn.chansend, jobid, esc .. "[201~")
    end

    -- If submit key includes an enter-equivalent, prefer sending a carriage-return (CR)
    -- rather than a newline. Use retry/delay to improve reliability with slow terminals.
    if util.contains_enter_key(submit_keys) then
      local function send_enter()
        local j = term_job_for_buf(bufnr)
        if j then pcall(vim.fn.chansend, j, "\r") end
      end

      -- First quick attempt to submit after sending text
      vim.defer_fn(send_enter, 10)

      -- Additional retries spaced by submit_delay
      for i = 1, (opts.submit_retry or submit_retry) do
        local delay = (opts.submit_delay or submit_delay) * i
        vim.defer_fn(send_enter, delay)
      end
    end
    return true
  else
    -- Not a terminal: append lines and optionally call done.
    local lines = vim.split(normalized_text, "\n")
    local last = math.max(0, vim.api.nvim_buf_line_count(bufnr))
    pcall(vim.api.nvim_buf_set_lines, bufnr, last, last, false, lines)
    if util.contains_enter_key(submit_keys) then
      -- For normal buffers, append an extra newline at the end
      pcall(vim.api.nvim_buf_set_lines, bufnr, last + #lines, last + #lines, false, { "" })
    end
    return true
  end
end

function M.capture_pane(target_pane, on_output)
  local bufnr = to_bufnum(target_pane)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    if on_output then vim.schedule(function() pcall(on_output, "") end) end
    return false
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local text = table.concat(lines, "\n")
  if on_output then
    vim.schedule(function() pcall(on_output, text) end)
  end
  return true
end

return M
