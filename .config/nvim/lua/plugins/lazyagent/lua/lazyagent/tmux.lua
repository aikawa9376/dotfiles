local M = {}
local DEFAULT_SUBMIT_DELAY_MS = 600
local DEFAULT_SUBMIT_RETRY = 1
local util = require("lazyagent.util")
local state = require("lazyagent.logic.state")
local POOL_SESSION = "lazyagent-pool"

-- Ensure the pool session exists.
function M.ensure_pool()
  local cmd_check = { "tmux", "has-session", "-t", POOL_SESSION }
  pcall(vim.fn.system, table.concat(cmd_check, " "))
  local exists = (vim.v.shell_error == 0)

  if not exists then
    -- Create pool synchronously
    local out = vim.fn.system({ "tmux", "new-session", "-d", "-s", POOL_SESSION, "-P", "-F", "#{pane_id}" })
    local dummy_id = out:gsub("%s+", "")
    vim.fn.system({ "tmux", "set-option", "-t", POOL_SESSION, "status", "off" })
    return dummy_id -- Return dummy id to kill if needed
  end
  return nil
end

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
function M.split(command, size, is_vertical, on_split_or_opts)
  local on_split = on_split_or_opts
  local opts = {}
  if type(on_split_or_opts) == "table" then
     opts = on_split_or_opts
     on_split = opts.on_split
  end

  -- create the pane in the background (don't switch focus) and print the pane id
  local args = { "split-window", "-d", "-P", "-F", "#{pane_id}" }
  
  local dummy_id_to_kill = nil
  -- If target session provided (e.g. pool), ensure it exists and target it
  if opts.target_session then
     if opts.target_session == POOL_SESSION then
        dummy_id_to_kill = M.ensure_pool()
     end
     table.insert(args, "-t")
     table.insert(args, opts.target_session)
  end

  -- 'is_vertical' here should match builtin/vsplit behavior (side-by-side).
  -- In tmux, side-by-side splits are created with '-h' (horizontal flag).
  if is_vertical then
    table.insert(args, "-h")
  end
  if size then
    local s = tostring(size)
    if s:match("%%$") then
      table.insert(args, "-p")
      table.insert(args, s:gsub("%%$", ""))
    elseif type(size) == "number" and size <= 100 then
       -- Heuristic: numbers <= 100 are likely percentages (legacy behavior)
       -- unless user explicitly wants cells, they should use string "80" or number > 100?
       -- But user wants to set fixed value.
       -- Let's assume if it's a number, it's percentage for backward compat, 
       -- UNLESS we change the default config to string "30%".
       -- But the user said "fixed value".
       -- Let's support string input without % as absolute.
       table.insert(args, "-p")
       table.insert(args, s)
    else
       -- String without % or number > 100 -> absolute lines/cells
       table.insert(args, "-l")
       table.insert(args, s)
    end
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
      if dummy_id_to_kill and pane_id ~= "" then
         run({ "kill-pane", "-t", dummy_id_to_kill })
      end
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

-- Attempt to exit tmux copy-mode on the target pane.
-- Tries the canonical `-X cancel` first (preferred), falling back to a keystroke
-- send (Escape) if the `-X` form isn't supported by the tmux on the user's system.
function M.exit_copy_mode(target_pane, on_done)
  on_done = on_done or function() end
  if not target_pane or target_pane == "" then
    on_done(false)
    return false
  end

  local ok, _ = run({ "send-keys", "-t", target_pane, "-X", "cancel" }, {
    on_exit = function(_, code, _)
      vim.schedule(function()
        if code == nil or code == 0 then
          on_done(true)
        else
          on_done(false)
        end
      end)
    end,
  })

  if not ok then
    -- If run couldn't start a job, fall back synchronously.
    run({ "send-keys", "-t", target_pane, "Escape" })
    on_done(false)
  end

  return true
end

-- Send keys to a tmux pane (keys is an array of strings).
-- If opts.skip_exit_copy_mode is not true and tmux_auto_exit_copy_mode is enabled in config,
-- attempt to exit tmux copy-mode first before sending the requested keys.
function M.send_keys(target_pane, keys, opts)
  opts = opts or {}
  if not keys then return end
  if type(keys) ~= "table" then keys = { keys } end

  -- Optionally auto-exit copy-mode before sending acceptance/submit keys (e.g., Enter/C-m).
  -- Only attempt to exit copy-mode when the key(s) being sent include an enter-equivalent.
  if not (opts and opts.skip_exit_copy_mode) and state and state.opts and state.opts.tmux_auto_exit_copy_mode and util.contains_enter_key(keys) then
    M.exit_copy_mode(target_pane, function()
      M.send_keys(target_pane, keys, vim.tbl_extend("force", opts or {}, { skip_exit_copy_mode = true }))
    end)
    return
  end

  local args = { "send-keys", "-t", target_pane }
  for _, key in ipairs(keys) do
    table.insert(args, key)
  end
  run(args)
end

function M.kill_pane(target_pane)
  run({ "kill-pane", "-t", target_pane })
end

function M.kill_pane_sync(target_pane)
  local cmd = "tmux kill-pane -t " .. vim.fn.shellescape(target_pane)
  vim.fn.system(cmd)
end

function M.get_pane_info(target_pane, on_info)
  run({ "display-message", "-p", "-F", "#{pane_width},#{pane_height}", "-t", target_pane }, {
    on_stdout = function(_, data)
      if data and data[1] then
        local w, h = data[1]:match("^(%d+),(%d+)$")
        if w and h and on_info then
          on_info({ width = tonumber(w), height = tonumber(h) })
        end
      end
    end
  })
end

function M.break_pane(target_pane)
  -- Check synchronously to avoid race conditions during rapid calls
  local dummy_id = M.ensure_pool()
  
  -- Join agent pane (async)
  run({ "join-pane", "-d", "-s", target_pane, "-t", POOL_SESSION }, {
    on_exit = function()
      -- Kill the dummy pane now that the agent is safely in the pool
      if dummy_id and dummy_id ~= "" then
        run({ "kill-pane", "-t", dummy_id })
      end
    end
  })
end

function M.break_pane_sync(target_pane)
  local dummy_id = M.ensure_pool()
  vim.fn.system("tmux join-pane -d -s " .. vim.fn.shellescape(target_pane) .. " -t " .. POOL_SESSION)
  
  if dummy_id and dummy_id ~= "" then
    vim.fn.system("tmux kill-pane -t " .. dummy_id)
  end
end

function M.join_pane(target_pane, size, is_vertical, on_done)
  -- tmux join-pane [-bdfhIv] [-l size] [-s src-pane] [-t dst-pane]
  -- Try putting size options BEFORE source/target options
  
  local args = { "join-pane", "-d" }
  
  if is_vertical then
    table.insert(args, "-h")
  end
  
  if size then
    local s = tostring(size)
    if s ~= "" then
      -- If it looks like a percentage, use -p, otherwise -l
      if s:match("%%$") or type(size) == "number" then
         table.insert(args, "-p")
         table.insert(args, s:gsub("%%$", ""))
      else
         table.insert(args, "-l")
         table.insert(args, s)
      end
    end
  end

  table.insert(args, "-s")
  table.insert(args, target_pane)
  
  local retrying = false
  run(args, {
    on_stderr = function(_, data)
      if data then
        local msg = table.concat(data, "")
        if msg and msg ~= "" then
          -- If join-pane fails with size, fallback to resize-pane method
          if msg:match("size") or msg:match("usage") or msg:match("too many arguments") then
             retrying = true
             -- vim.notify("LazyAgent: join-pane failed (" .. msg .. "), retrying without size...", vim.log.levels.WARN)
             -- Retry without size argument
             M.join_pane(target_pane, nil, is_vertical, function(ok)
                if ok and size then
                   -- If join succeeded, try to resize explicitly
                   local resize_args = { "resize-pane", "-t", target_pane }
                   
                   -- Note: is_vertical in lazyagent means side-by-side (vsplit), which corresponds to tmux -h.
                   -- For side-by-side, we want to adjust width (-x).
                   if is_vertical then
                      table.insert(resize_args, "-x")
                   else
                      table.insert(resize_args, "-y")
                   end
                   
                   local s = tostring(size)
                   if s:match("%%$") then
                      table.insert(resize_args, s)
                   elseif type(size) == "number" and size <= 100 then
                      table.insert(resize_args, s .. "%")
                   else
                      table.insert(resize_args, s)
                   end
                   
                   -- Add a small delay before resizing to ensure layout has settled
                   vim.defer_fn(function()
                     run(resize_args, {
                        on_exit = function()
                           if on_done then on_done(true) end
                        end
                     })
                   end, 100) -- Increased delay slightly to 100ms
                else
                   if on_done then on_done(ok) end
                end
             end)
             return
          else
             vim.notify("LazyAgent join-pane error: " .. msg, vim.log.levels.ERROR)
          end
        end
      end
    end,
    on_exit = function(_, code)
      if not retrying and on_done then
        vim.schedule(function() on_done(code == 0) end)
      end
    end,
  })
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

function M.cleanup_if_idle()
  -- No-op: tmux handles session destruction automatically when the last pane is removed.
  -- We rely on prune_dummy_pane to remove the placeholder pane once a real agent pane enters the pool.
end

-- Save a text into tmux buffer name 'lazyagent-tmp'
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
  run({ "load-buffer", "-b", "lazyagent-tmp", tmpfile }, {
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
  local args = { "paste-buffer", "-b", "lazyagent-tmp", "-t", target_pane }
  local ok, ret = run(args, {
    on_exit = function(_, _, _)
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
  local move_to_end = opts.move_to_end or false
  local use_bracketed_paste = opts.use_bracketed_paste or false

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

  local function maybe_move_to_end()
    if move_to_end then
      -- The tmux 'send-keys' C-e should place the cursor at end of line for most shells
      M.send_keys(target_pane, { "C-e" })
    end
  end

  local esc = string.char(27)
  local start_br = esc .. "[200~"
  local end_br = esc .. "[201~"

  M.set_buffer(normalized_text, function()
    maybe_move_to_end()
    if use_bracketed_paste then M.send_keys(target_pane, { start_br }) end
    -- Attempt to paste; if paste returns false, fallback to send-keys -l
    local pasted = M.paste(target_pane, {
      on_done = function()
        if use_bracketed_paste then M.send_keys(target_pane, { end_br }) end
        schedule_submits()
      end,
    })
    if not pasted then
      if use_bracketed_paste then
        run({ "send-keys", "-t", target_pane, "-l", start_br .. normalized_text .. end_br })
      else
        run({ "send-keys", "-t", target_pane, "-l", normalized_text })
      end
      schedule_submits()
    end
  end, { debug = debug })

  return true
end

-- Capture the content of a tmux pane and return the text to on_output callback.
function M.capture_pane(target_pane, on_output)
  -- Use -J to join wrapped lines and ensure a better-looking capture.
  local args = { "capture-pane", "-J", "-p", "-S", "-", "-t", target_pane }
  local collected = {}
  run(args, {
    on_stdout = function(_, data)
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

function M.capture_pane_sync(target_pane)
  local args = { "capture-pane", "-J", "-p", "-S", "-", "-t", target_pane }
  local cmd_arr = vim.list_extend({ "tmux" }, args)
  local cmd_str = table.concat(vim.tbl_map(function(s) return vim.fn.shellescape(tostring(s)) end, cmd_arr), " ")
  local ok, lines = pcall(vim.fn.systemlist, cmd_str)
  if not ok or type(lines) ~= "table" then return "" end

  local collected = {}
  local esc = string.char(27)
  for _, d in ipairs(lines) do
    if d and d ~= "" then
      if not d:match(esc .. "P.*kitty") then
        table.insert(collected, d)
      end
    end
  end
  return table.concat(collected, "\n")
end

return M
