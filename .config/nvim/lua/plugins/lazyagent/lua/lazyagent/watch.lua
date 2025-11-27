-- watch.lua
-- Lightweight file watch manager for lazyagent.
-- Inspired by sidekick-watch.lua but keeps lazyagent extensions like per-buffer reloads.
-- This simplified manager uses uv.fs_event watchers per directory with a fallback to
-- FileChangedShellPost autocmds, and exposes convenience APIs:
--  - M.add(path, cb, opts)
--  - M.remove(handle)
--  - M.watch_buffer(bufnr, opts)
--  - M.suspend(path_or_bufnr, ms)
--  - M.is_watching(path_or_bufnr)
--  - M.start(dir_or_file), M.stop(dir), M.update(), M.enable(), M.disable(), M.list()
--
-- It also provides a 'refresh' method (debounced) which runs vim.cmd.checktime() and
-- clears the internal changes log.

local M = {}
local uv = vim.loop
-- Fallback for unpacking argument tables in environments where table.unpack/unpack might be unavailable.
local _unpack = table.unpack or unpack
local function _safe_unpack(t)
  -- Use the native table.unpack/unpack if available; else provide a safe, limited fallback
  if _unpack then
    return _unpack(t)
  end
  -- Best-effort fallback: return up to 10 values (covers common use cases)
  if not t then return end
  return t[1], t[2], t[3], t[4], t[5], t[6], t[7], t[8], t[9], t[10]
end

local DEFAULT_DEBOUNCE_MS = 300
local DEFAULT_REFRESH_MS = 100

-- Expose watcher set
local watchers = {}
M.watches = watchers

-- Per-directory change log (path -> true)
local changes = {}

-- Next callback id
local next_cb_id = 1

-- Suspended paths to ignore for a short duration
local ignore_until = {}

-- Exported enabled state and autogroup name
M.enabled = false
local AUTOCMD_GROUP_NAME = "lazyagent.watch"

-- Helper: canonicalize an absolute path
local function abs_path(p)
  if not p or p == "" then return nil end
  return vim.fn.fnamemodify(p, ":p")
end

-- Helper: get absolute path and directory/base parts
local function dir_and_base_from_path(p)
  local a = abs_path(p)
  if not a then return nil, nil, nil end
  local dir = vim.fn.fnamemodify(a, ":h")
  local base = vim.fn.fnamemodify(a, ":t")
  return a, dir, base
end

-- Debounce helper (per-directory debouncing)
local function debounce(fn, ms)
  ms = ms or DEFAULT_REFRESH_MS
  local timer = nil
  return function(...)
    local args = { ... }
    if timer then
      pcall(function() timer:stop() end)
      pcall(function() timer:close() end)
      timer = nil
    end
    timer = uv.new_timer()
    timer:start(ms, 0, function()
      pcall(function() timer:stop() end)
      pcall(function() timer:close() end)
      timer = nil
      vim.schedule(function()
        pcall(fn, _safe_unpack(args))
      end)
    end)
  end
end

-- Global debounced refresh to call checktime and clear the changes log
local function refresh()
  -- Nothing to do
  if not next(changes) then return end
  -- Run checktime to let Vim notice changed files
  vim.cmd.checktime()
  -- Debug log of changes if any (best-effort)
  local keys = vim.tbl_keys(changes)
  pcall(function()
    if #keys > 0 then
      pcall(vim.notify, "# lazyagent.watch: changes\n- " .. table.concat(keys, "\n- "), vim.log.levels.DEBUG)
    end
  end)
  changes = {}
end
local refresh_debounced = debounce(refresh, DEFAULT_REFRESH_MS)

-- Per-watcher debounce to collapse multiple events
local function schedule_debounce(w, path, ms)
  ms = ms or DEFAULT_DEBOUNCE_MS
  if not w then return end

  -- Record change
  if path and path ~= "" then changes[path] = true end

  -- Cancel previous timer if any
  if w.timer then
    pcall(function() w.timer:stop() end)
    pcall(function() w.timer:close() end)
    w.timer = nil
  end

  local t = uv.new_timer()
  w.timer = t
  t:start(ms, 0, function()
    pcall(function()
      t:stop()
      t:close()
      w.timer = nil
    end)
    -- Call callbacks on the main loop
    vim.schedule_wrap(function()
      for _, cb in pairs(w.cbs or {}) do
        pcall(cb, path)
      end
      -- Also trigger global checktime refresh (debounced)
      refresh_debounced()
    end)()
  end)
end

-- Create a directory watcher and register callbacks bucket
-- dir may be an absolute directory path
local function create_watcher_for_dir(dir, opts)
  opts = opts or {}
  if not dir or dir == "" then return nil end
  dir = abs_path(dir)
  if not dir then return nil end

  -- Key is just the directory
  local key = dir
  if watchers[key] then return watchers[key] end

  local w = { dir = dir, cbs = {}, timer = nil, handle = nil, autocmd_group = nil }
  -- Prefer uv.fs_event when available
  local ok_fs_event = uv and uv.new_fs_event and true or false
  if ok_fs_event then
    local ok, handle_or_err = pcall(function() return uv.new_fs_event() end)
    local handle = ok and handle_or_err or nil
    if handle then
      w.handle = handle
      local function on_event(err, filename)
        if err and err ~= "" then
          pcall(function()
            vim.schedule(function()
              pcall(vim.notify, "lazyagent.watch fs_event error: " .. tostring(err), vim.log.levels.WARN)
            end)
          end)
          return
        end

        local fname = filename or ""
        local path = nil
        if fname == "" or not fname then
          path = dir
        else
          path = abs_path(dir .. "/" .. fname)
        end
        if not path then return end

        if ignore_until[path] and ignore_until[path] > uv.now() then return end

        schedule_debounce(w, path, opts.debounce_ms or DEFAULT_DEBOUNCE_MS)
      end

      local started_ok, start_res = pcall(function() return handle:start(dir, {}, on_event) end)
      -- handle:start may return true on success; if pcall failed or it returned false/nil, fallback
      if not started_ok or not start_res then
        if w.handle and w.handle.stop and w.handle.close then
          pcall(function() w.handle:stop() end)
          pcall(function() w.handle:close() end)
        end
        w.handle = nil
        ok_fs_event = false
      end
    else
      ok_fs_event = false
    end
  end

  -- Fallback: FileChangedShellPost autocmd per-directory (best-effort)
  if not ok_fs_event then
    local gid = vim.api.nvim_create_augroup("LazyAgentWatchFallback_" .. vim.fn.sha1(dir), { clear = true })
    w.autocmd_group = gid
    vim.api.nvim_create_autocmd("FileChangedShellPost", {
      group = gid,
      pattern = "*",
      callback = function(args)
        local file = args and args.file or nil
        local path = file or dir
        path = abs_path(path)
        if not path then return end
        if ignore_until[path] and ignore_until[path] > uv.now() then return end
        schedule_debounce(w, path, opts.debounce_ms or DEFAULT_DEBOUNCE_MS)
      end,
    })
  end

  watchers[key] = w
  M.watches = watchers
  return w
end

-- Start watching a path (file or directory). If path is a file, the watcher monitors its directory.
-- Returns the watcher object or nil on failure.
function M.start(path, opts)
  if not path or path == "" then return nil end
  if type(path) == "number" then path = vim.api.nvim_buf_get_name(path) end
  local abs = abs_path(path)
  if not abs then return nil end
  local _, dir = pcall(function() return vim.fn.fnamemodify(abs, ":h") end)
  if not dir or dir == "" then return nil end
  return create_watcher_for_dir(dir, opts)
end

-- Stop watching the given directory path (string) or a handle produced by M.start
function M.stop(path_or_key)
  if not path_or_key then return end
  local key = path_or_key
  if type(path_or_key) == "table" and path_or_key.dir then
    key = path_or_key.dir
  elseif type(path_or_key) == "number" then
    local p = vim.api.nvim_buf_get_name(path_or_key)
    key = p and abs_path(vim.fn.fnamemodify(p, ":h"))
  else
    key = abs_path(vim.fn.fnamemodify(path_or_key, ":p"))
    key = key and vim.fn.fnamemodify(key, ":h")
    -- Ensure the key always matches the canonical absolute directory format.
    key = key and abs_path(key)
  end
  if not key then return end
  local w = watchers[key]
  if not w then return end
  if w.handle and w.handle.stop and w.handle.close then
    pcall(function() w.handle:stop() end)
    pcall(function() w.handle:close() end)
  end
  if w.timer then
    pcall(function() w.timer:stop() end)
    pcall(function() w.timer:close() end)
  end
  if w.autocmd_group then
    pcall(vim.api.nvim_del_augroup_by_id, w.autocmd_group)
  end
  watchers[key] = nil
  M.watches = watchers
end

-- Update watchers to reflect currently loaded buffers: start watches for new buffer directories,
-- and stop watchers for directories without any active buffers.
local function dirname_for_buf(buf)
  local fname = vim.api.nvim_buf_get_name(buf)
  if
    vim.api.nvim_buf_is_loaded(buf)
    and vim.bo[buf].buftype == ""
    and vim.bo[buf].buflisted
    and fname ~= ""
    and uv.fs_stat(fname) ~= nil
  then
    local p = vim.fs and vim.fs.dirname(fname) or vim.fn.fnamemodify(fname, ":h")
    -- Normalize to the canonical absolute directory form used as watcher keys.
    local abs = abs_path(p)
    return abs and abs ~= "" and abs or nil
  end
end

function M.update()
  local dirs = {}
  for _, buf in pairs(vim.api.nvim_list_bufs()) do
    local d = dirname_for_buf(buf)
    if d then
      dirs[d] = true
      if not watchers[d] then
        M.start(d)
      end
    end
  end

  for k in pairs(watchers) do
    if not dirs[k] then
      M.stop(k)
    end
  end
end

-- Debounced update (protect against rapid Buf events)
M.update = debounce(M.update, DEFAULT_REFRESH_MS)

-- Add a specific path (file or dir) watcher and register a callback (cb receives absolute path).
-- Returns a handle you can use with M.remove()
function M.add(path, cb, opts)
  if not path or not cb then return nil end
  if type(path) == "number" then
    path = vim.api.nvim_buf_get_name(path)
  end
  local abs = abs_path(path)
  if not abs then return nil end
  local _, dir, base = dir_and_base_from_path(abs)
  if not dir then return nil end
  local w = create_watcher_for_dir(dir, opts)
  if not w then return nil end
  local id = tostring(next_cb_id); next_cb_id = next_cb_id + 1
  w.cbs[id] = cb
  return { id = id, abs = abs, dir = dir, base = base, key = dir }
end

-- Remove a watcher handle returned by M.add
function M.remove(handle)
  if not handle then return false end
  local key = handle.key or handle.dir
  if not key then
    local abs = handle.abs and abs_path(handle.abs)
    if not abs then return false end
    key = vim.fn.fnamemodify(abs, ":h")
  end
  local w = watchers[key]
  if not w then return false end
  if handle.id and w.cbs[handle.id] then w.cbs[handle.id] = nil end
  -- remove watcher if no callbacks remain
  local anycbs = false
  for _, _ in pairs(w.cbs) do anycbs = true break end
  if not anycbs then
    M.stop(key)
  end
  return true
end

-- Watch a buffer's file and reload buffer on external modifications
-- opts: { notify_if_modified = true|false, on_reload = function(bufnr, path), on_not_reloaded = function(bufnr, path) }
function M.watch_buffer(bufnr, opts)
  opts = opts or {}
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return nil end
  local path = vim.api.nvim_buf_get_name(bufnr)
  if not path or path == "" then return nil end
  local abs = abs_path(path)
  if not abs then return nil end

  local function default_cb(changed_abs)
    changed_abs = changed_abs or abs
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    if vim.bo[bufnr].buftype == "nofile" then return end
    if vim.bo[bufnr].modified then
      if opts.notify_if_modified ~= false then
        vim.schedule(function()
          pcall(vim.notify, "File changed on disk: buffer is modified; not reloading", vim.log.levels.INFO)
        end)
      end
      if opts.on_not_reloaded then pcall(opts.on_not_reloaded, bufnr, changed_abs) end
      return
    end

    local ok, lines = pcall(vim.fn.readfile, changed_abs)
    if ok and lines then
      vim.schedule(function()
        pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, lines)
        if opts.on_reload then pcall(opts.on_reload, bufnr, changed_abs) end
      end)
    end
  end

  local cb = opts.on_change or default_cb
  local handle = M.add(abs, cb, opts)
  return handle
end

-- Suspend (ignore) watch events for a path for a duration (ms)
function M.suspend(p, ms)
  ms = ms or 1500
  local path = p
  if type(p) == "number" then path = vim.api.nvim_buf_get_name(p) end
  local abs = abs_path(path)
  if not abs then return false end
  ignore_until[abs] = uv.now() + ms
  return true
end

-- Check if path is currently being watched.
function M.is_watching(path)
  if not path then return false end
  if type(path) == "number" then path = vim.api.nvim_buf_get_name(path) end
  local abs = abs_path(path)
  if not abs then return false end
  local d = vim.fn.fnamemodify(abs, ":h")
  return watchers[d] ~= nil
end

-- Stop and clear all watchers.
function M.stop_all()
  for k, w in pairs(watchers) do
    if w.handle and w.handle.stop and w.handle.close then
      pcall(function() w.handle:stop() end)
      pcall(function() w.handle:close() end)
    end
    if w.timer then
      pcall(function() w.timer:stop() end)
      pcall(function() w.timer:close() end)
    end
    if w.autocmd_group then
      pcall(vim.api.nvim_del_augroup_by_id, w.autocmd_group)
    end
    watchers[k] = nil
  end
  M.watches = watchers
end

-- Backwards-compatible alias used earlier (keep per-directory M.stop)
-- Keep M.stop (per-directory) and M.stop_all (stop all) distinct to avoid surprising behavior.

-- List server watchers.
function M.list()
  local out = {}
  for k, w in pairs(watchers) do
    table.insert(out, { key = k, dir = w.dir, cb_count = vim.tbl_count(w.cbs) })
  end
  return out
end

-- Enable file system watching for all loaded buffers
function M.enable()
  if M.enabled then return end
  M.enabled = true
  pcall(vim.notify, "lazyagent.watch: enabled", vim.log.levels.DEBUG)
  vim.api.nvim_create_autocmd({ "BufAdd", "BufDelete", "BufWipeout", "BufReadPost" }, {
    group = vim.api.nvim_create_augroup(AUTOCMD_GROUP_NAME, { clear = true }),
    callback = M.update,
  })
  M.update()
end

-- Disable file system watching and stop all active watches
function M.disable()
  if not M.enabled then return end
  M.enabled = false
  pcall(vim.notify, "lazyagent.watch: disabled", vim.log.levels.DEBUG)
  pcall(vim.api.nvim_clear_autocmds, { group = AUTOCMD_GROUP_NAME })
  pcall(vim.api.nvim_del_augroup_by_name, AUTOCMD_GROUP_NAME)
  M.stop_all()
end

return M
