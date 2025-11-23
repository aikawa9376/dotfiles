local M = {}
local DEFAULT_SUBMIT_DELAY_MS = 600
local DEFAULT_SUBMIT_RETRY = 1
local util = require("send-agent.util")

-- Run tmux command asynchronously using jobstart; fallback to a synchronous
-- system call. This wrapper validates opts and captures jobstart errors.
local function run(args, opts)
  opts = opts or {}
  local cmd_arr = vim.list_extend({ "tmux" }, args or {})
  local cmd_str = table.concat(vim.tbl_map(function(s) return vim.fn.shellescape(tostring(s)) end, cmd_arr), " ")

  -- Fast path: no callbacks -> try jobstart without options; fallback to system.
  if next(opts) == nil then
    local ok, job_or_err = pcall(vim.fn.jobstart, cmd_arr, {})
    if ok and job_or_err and job_or_err > 0 then
      return true, job_or_err
    end
    -- fallback to synchronous system call
    local ok2, out = pcall(vim.fn.system, cmd_str)
    if ok2 then return true, out end
    return false
  end

  -- Wrap callbacks to ensure they're scheduled on the main loop
  local function wrap_stdout(f)
    if not f then return nil end
    return function(jobid, data, event)
      if not data then data = {} end
      vim.schedule_wrap(function()
        pcall(f, jobid, data, event)
      end)()
    end
  end
  local function wrap_exit(f)
    if not f then return nil end
    return function(jobid, code, event)
      vim.schedule_wrap(function()
        pcall(f, jobid, code, event)
      end)()
    end
  end

  local jop = {}
  if opts.on_stdout then jop.on_stdout = wrap_stdout(opts.on_stdout) end
  if opts.on_stderr then jop.on_stderr = wrap_stdout(opts.on_stderr) end
  if opts.on_exit then jop.on_exit = wrap_exit(opts.on_exit) end

  local ok, job_or_err = pcall(vim.fn.jobstart, cmd_arr, jop)
  if ok and job_or_err and job_or_err > 0 then
    return true, job_or_err
  end

  -- fallback to synchronous systemlist so callbacks get data immediately
  local ok2, lines = pcall(vim.fn.systemlist, cmd_str)
  if ok2 then
    if opts.on_stdout then
      pcall(opts.on_stdout, 0, lines, "stdout")
    end
    if opts.on_exit then
      pcall(opts.on_exit, 0, 0, "exit")
    end
    return true, lines

  end

  vim.notify("tmux.run: jobstart failed and system fallback failed", vim.log.levels.WARN)
  return false
end

-- Split a new tmux pane and return the pane id through on_split callback.
function M.split(command, size, is_vertical, on_split)
  -- create the pane in the background (don't switch focus) and print the pane id
  local args = { "split-window", "-d", "-P", "-F", "#{pane_id}" }
  if is_vertical then
    table.insert(args, "-v")
  end
  if size then
    table.insert(args, "-p")
    table.insert(args, tostring(size))
  end
  if command and #command > 0 then
    table.insert(args, command)
  end

  local pane_id = ""
  run(args, {
    on_stdout = function(_, data)
      if not data then return end
      local esc = string.char(27)
      for _, d in ipairs(data) do
        if d and d ~= "" then
          local line = d:gsub("^%s*(.-)%s*$", "%1")
          -- Ignore any control sequences or lines that contain ESC and prefer the tmux
          -- pane id format such as "%123" or "@serverid".
          if not line:find(esc, 1, true) and (line:match("^%%%d+$") or line:match("^@[%w-]+$")) then
            pane_id = line
            break
          end
        end
      end
    end,
    on_exit = function()
      if on_split and pane_id ~= "" then
        -- schedule on_split on the main loop
        vim.schedule_wrap(on_split)(pane_id)
      end
    end,
  })
end

function M.pane_exists(pane_id)
  if not pane_id or pane_id == "" then
    return false
  end
  -- Avoid doubling the "tmux" binary and build the proper shell command.
  local args = { "list-panes", "-a", "-F", "#{pane_id}" }
  local cmd_arr = vim.list_extend({ "tmux" }, args)
  local cmd = table.concat(vim.tbl_map(function(s) return vim.fn.shellescape(tostring(s)) end, cmd_arr), " ")
  local ok, lines = pcall(vim.fn.systemlist, cmd)
  if not ok or not lines or type(lines) ~= "table" then
    return false
  end
  for _, l in ipairs(lines) do
    if l and l == pane_id then
      return true
    end
  end
  return false
end

-- Send keys to a tmux pane (keys is an array of strings)
function M.send_keys(target_pane, keys)
  local args = { "send-keys", "-t", target_pane }
  for _, key in ipairs(keys) do
    table.insert(args, key)
  end
  run(args)
end

function M.kill_pane(target_pane)
  run({ "kill-pane", "-t", target_pane })
end

function M.copy_mode(target_pane)
  run({ "copy-mode", "-t", target_pane })
end

function M.scroll_up(target_pane)
  M.copy_mode(target_pane)
  M.send_keys(target_pane, { "PageUp" })
end

function M.scroll_down(target_pane)
  M.copy_mode(target_pane)
  M.send_keys(target_pane, { "PageDown" })
end

-- Save a text into tmux buffer name 'send-agent-tmp'
function M.set_buffer(text, on_done, opts)
  opts = opts or {}
  local debug = opts.debug or false
  local tmpfile = vim.fn.tempname()
  -- Normalize CRLF -> LF and ensure trailing newline so tmux paste processes the input consistently.
  local normalized_text = util.normalize_text(text)
  -- Write raw text to file to avoid an extra blank line caused by writefile(vim.split(...))
  local f = assert(io.open(tmpfile, "wb"))
  f:write(normalized_text)
  f:close()
  if debug then
    vim.schedule(function()
      pcall(vim.notify, "tmux.set_buffer: wrote buffer to " .. tmpfile, vim.log.levels.DEBUG)
    end)
  end
  run({ "load-buffer", "-b", "send-agent-tmp", tmpfile }, {
    on_exit = function()
      if debug then
        vim.schedule(function()
          pcall(vim.notify, "tmux.set_buffer: load-buffer finished " .. tmpfile, vim.log.levels.DEBUG)
        end)
      end
      vim.fn.delete(tmpfile)
      if on_done then
        vim.schedule(on_done)
      end
    end,
  })
end

function M.paste(target_pane, opts)
  opts = opts or {}
  local on_done = opts.on_done
  local args = { "paste-buffer", "-b", "send-agent-tmp", "-t", target_pane }
  local ok, ret = run(args, {
    on_exit = function(jobid, code, event)
      if on_done then
        vim.schedule_wrap(on_done)(true)
      end
    end,
  })
  if ok then
    -- If run() used a synchronous fallback (returns lines), on_exit won't run; call callback now.
    if type(ret) ~= "number" then
      if on_done then
        vim.schedule_wrap(on_done)(true)
      end
    end
    return true
  end
  return false
end

-- Convenience: paste text content then submit it (default submit key: Ctrl-m)
-- Adds a small small delay to increase robustness of the order:
-- 1) load-buffer, 2) paste-buffer (if available) or send-keys -l fallback, 3) send-keys (submit)
function M.paste_and_submit(target_pane, text, submit_keys, opts)
  opts = opts or {}
  submit_keys = submit_keys or { "C-m" }
  local submit_delay = opts.submit_delay or DEFAULT_SUBMIT_DELAY_MS
  local submit_retry = opts.submit_retry or DEFAULT_SUBMIT_RETRY
  local debug = opts.debug or false

  -- Normalize text and ensure trailing newline; this mirrors M.set_buffer behavior.
  local normalized_text = util.normalize_text(text)

  -- Helper: determine if submit key list contains an enter-equivalent
  local function _contains_enter(keys)
    -- use util helper, keeps logic centralized and consistent
    return util.contains_enter_key(keys)
  end

  -- schedule submit function (may be called from paste on_done callback or fallback)
  local function schedule_submits()
    if debug then
      vim.schedule(function()
        pcall(vim.notify, "tmux.paste_and_submit: scheduling submits (retry=" .. tostring(submit_retry) .. " delay=" .. tostring(submit_delay) .. ")", vim.log.levels.DEBUG)
      end)
    end
    for i = 1, submit_retry do
      local delay = submit_delay * i
      vim.defer_fn(function() M.send_keys(target_pane, submit_keys) end, delay)
    end
    -- If submit_keys doesn't include an Enter-equivalent, send one explicitly as a final attempt.
    if not _contains_enter(submit_keys) then
      vim.defer_fn(function() M.send_keys(target_pane, { "C-m" }) end, submit_delay * (submit_retry + 1))
    end
  end

  M.set_buffer(normalized_text, function()
    -- Attempt to paste; if paste returns false, fallback to send-keys -l
    local pasted = M.paste(target_pane, {
      on_done = function()
        schedule_submits()
      end,
    })
    if not pasted then
      -- fallback: send text directly via send-keys -l if buffer load/paste fails
      run({ "send-keys", "-t", target_pane, "-l", normalized_text })
      schedule_submits()
    end
  end, { debug = debug })

  return true
end

-- Capture the content of a tmux pane and return the text to on_output callback.
function M.capture_pane(target_pane, on_output)
  -- Use -J to join wrapped lines and ensure a better-looking capture.
  local args = { "capture-pane", "-J", "-p", "-t", target_pane }
  local collected = {}
  run(args, {
    on_stdout = function(jobid, data)
      if not data then return end
      local esc = string.char(27)
      for _, d in ipairs(data) do
        if d and d ~= "" then
          -- Filter out kitty device control strings (which show like ESC P ... ESC \),
          -- particularly those that embed 'kitty(...)' metadata, so they don't become
          -- visible captured lines. Leave normal ANSI color escapes untouched.
          if not d:match(esc .. "P.*kitty") then
            table.insert(collected, d)
          end
        end
      end
    end,
    on_exit = function()
      if on_output then
        local text = table.concat(collected, "\n")
        vim.schedule(function()
          pcall(on_output, text)
        end)
      end
    end,
  })
end

return M
