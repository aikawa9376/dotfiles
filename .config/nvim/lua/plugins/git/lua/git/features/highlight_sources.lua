-- Complete files for syntax coloring only. Structural comparison retains its
-- hunk-local sources. Each view shares reads between its displayed hunks.
local M = {}
local jobs = require('git.features.highlight_jobs')
local MAX_BYTES, CACHE_SIZE, CONCURRENCY = 1000000, 8, 2

local function fingerprint(path)
  local stat = path and vim.uv.fs_lstat(path)
  if not stat then return '-' end
  return table.concat({ stat.type, stat.ino, stat.size, stat.mtime.sec, stat.mtime.nsec,
    stat.ctime.sec, stat.ctime.nsec }, ':')
end

function M.key(spec)
  local function side(source)
    return source.path and { source.path, fingerprint(source.path) } or { source.object or '', source.text or '' }
  end
  return vim.mpack.encode({ spec.root or '', spec.path or '', side(spec.old), side(spec.new),
    spec.index_path and fingerprint(spec.index_path) or '' })
end

function M.new()
  local session = { cache = {}, pending = {}, queue = {}, count = 0, clock = 0 }
  local pump
  local function live(entry)
    if session.closed then return false end
    for _, listener in ipairs(entry.listeners) do if listener.valid() then return true end end
    return false
  end
  local function finish(entry, sources)
    if entry.finished then return end
    entry.finished = true
    session.pending[entry.key] = nil
    if entry.started then session.count = session.count - 1 end
    if live(entry) then
      if entry.key ~= M.key(entry.spec) then sources = nil end
      session.clock = session.clock + 1
      session.cache[entry.key] = { sources = sources, used = session.clock }
      local count, oldest, age = 0, nil, math.huge
      for key, cached in pairs(session.cache) do
        count = count + 1
        if cached.used < age then oldest, age = key, cached.used end
      end
      if count > CACHE_SIZE then session.cache[oldest] = nil end
      for _, listener in ipairs(entry.listeners) do
        if listener.valid() then listener.callback(sources) end
      end
    end
    if not session.closed then jobs.schedule(pump) end
  end
  local function load(entry, source, callback)
    if not live(entry) then finish(entry); return end
    local function loaded(text)
      if not live(entry) then finish(entry); return end
      if not text or #text > MAX_BYTES or text:find('\0', 1, true) then finish(entry); return end
      local lines = vim.split(text:gsub('\r\n', '\n'), '\n', { plain = true })
      if text:sub(-1) == '\n' then lines[#lines] = nil end
      callback(lines)
    end
    if source.text ~= nil then loaded(source.text); return end
    if source.object then
      local ok, job = pcall(vim.system, { 'git', '--no-optional-locks', 'show', source.object },
        { cwd = entry.spec.root, text = false, timeout = 5000 }, function(result)
          vim.schedule(function()
            entry.job = nil
            loaded(result.code == 0 and result.stdout or nil)
          end)
        end)
      if ok then entry.job = job else finish(entry) end
      return
    end
    local stat = source.path and vim.uv.fs_lstat(source.path)
    if stat and stat.type == 'link' then
      vim.uv.fs_readlink(source.path, function(err, target)
        vim.schedule(function() loaded(not err and target or nil) end)
      end)
      return
    end
    if not stat or stat.type ~= 'file' or stat.size > MAX_BYTES then finish(entry); return end
    vim.uv.fs_open(source.path, 'r', 0, function(err, fd)
      if not fd then vim.schedule(function() loaded(nil) end); return end
      local function close(text)
        vim.uv.fs_close(fd, function() vim.schedule(function() loaded(text) end) end)
      end
      vim.uv.fs_fstat(fd, function(stat_err, current)
        if stat_err or not current or current.type ~= 'file' or current.size > MAX_BYTES
          or session.closed or entry.cancelled then close(nil); return end
        local parts, offset = {}, 0
        local function read()
          if session.closed or entry.cancelled then close(nil); return end
          if offset == current.size then close(table.concat(parts)); return end
          vim.uv.fs_read(fd, math.min(65536, current.size - offset), offset, function(read_err, data)
            if read_err or not data or data == '' then close(nil); return end
            parts[#parts + 1], offset = data, offset + #data
            read()
          end)
        end
        read()
      end)
    end)
  end
  pump = function()
    while not session.closed and session.count < CONCURRENCY and #session.queue > 0 do
      local entry = table.remove(session.queue, 1)
      if not live(entry) then finish(entry)
      else
        session.count, entry.started = session.count + 1, true
        load(entry, entry.spec.old, function(old)
          load(entry, entry.spec.new, function(new) finish(entry, { old = old, new = new }) end)
        end)
      end
    end
  end
  function session.request(spec, valid, callback)
    if session.closed then return end
    local key = M.key(spec)
    local cached = session.cache[key]
    if cached then
      session.clock = session.clock + 1; cached.used = session.clock
      if valid() then callback(cached.sources) end
      return
    end
    local listener = { valid = valid, callback = callback }
    if session.pending[key] then
      table.insert(session.pending[key].listeners, listener)
      return
    end
    local entry = { key = key, spec = spec, listeners = { listener } }
    session.pending[key] = entry
    session.queue[#session.queue + 1] = entry
    -- No Git reads or source splitting starts on the attach/refresh stack.
    jobs.schedule(pump)
  end
  function session.prune()
    local cancelled = {}
    for _, entry in pairs(session.pending) do
      if not live(entry) then
        entry.cancelled = true
        if entry.job then pcall(entry.job.kill, entry.job, 15) end
        cancelled[#cancelled + 1] = entry
      end
    end
    -- Reopening the same source must start fresh, rather than joining a killed
    -- read whose callback has not arrived yet. Late callbacks are inert.
    for _, entry in ipairs(cancelled) do finish(entry) end
  end
  function session.close()
    session.closed = true
    session.prune()
    session.cache, session.queue = {}, {}
  end
  return session
end

return M
