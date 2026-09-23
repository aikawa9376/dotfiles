-- OS notifications invalidate cached status after Git commands outside Neovim.
local M = {}
local uv = vim.uv
local repositories = {}
local check, enqueue

local function live(repo) return repositories[repo.dir] == repo end

local function close(handle)
  handle:stop()
  handle:close()
end

local function read(path, callback)
  uv.fs_open(path, 'r', 438, function(err, fd)
    if err then callback(''); return end
    uv.fs_read(fd, 4096, 0, function(_, data)
      uv.fs_close(fd, function() callback(data or '') end)
    end)
  end)
end

local function watch_paths(repo, paths, common)
  local wanted = {}
  for _, path in ipairs(paths) do
    local dir = vim.fs.dirname(path)
    -- Watch parents as well: Git atomically replaces refs and creates/deletes
    -- nested branch directories. A watch on the ref inode would go stale.
    while dir and (dir == repo.dir or dir == common or dir:sub(1, #common + 1) == common .. '/') do
      wanted[dir] = true
      if dir == repo.dir or dir == common then break end
      dir = vim.fs.dirname(dir)
    end
  end
  for dir, handle in pairs(repo.handles) do
    if not wanted[dir] then repo.handles[dir] = nil; close(handle) end
  end
  for dir in pairs(wanted) do
    if not repo.handles[dir] then
      local handle = uv.new_fs_event()
      if handle then
        local ok = handle:start(dir, {}, function(err, filename, events)
          vim.schedule(function()
            if not live(repo) then return end
            -- A renamed/deleted watched directory may invalidate the watch.
            if (err or (events and events.rename and filename == vim.fs.basename(dir)))
              and repo.handles[dir] == handle then
              repo.handles[dir] = nil
              close(handle)
            end
            enqueue(repo)
          end)
        end)
        if ok then repo.handles[dir] = handle else handle:close() end
      end
    end
  end
end

enqueue = function(repo)
  if not live(repo) then return end
  if repo.pending then repo.again = true; return end
  if repo.debounce then return end
  local timer = uv.new_timer()
  repo.debounce = timer
  timer:start(75, 0, function()
    vim.schedule(function()
      if repo.debounce ~= timer then return end
      repo.debounce = nil
      timer:close()
      if live(repo) then check(repo) end
    end)
  end)
end

check = function(repo)
  if repo.pending or not live(repo) then return end
  repo.pending = true
  read(repo.dir .. '/HEAD', function(head)
    read(repo.dir .. '/commondir', function(common)
      common = common:gsub('%s+$', '')
      local dir = common ~= '' and (common:sub(1, 1) == '/' and common or repo.dir .. '/' .. common) or repo.dir
      dir = vim.fs.normalize(dir)
      local paths = { repo.dir .. '/index', repo.dir .. '/HEAD', repo.dir .. '/FETCH_HEAD', dir .. '/packed-refs' }
      local ref = head:match('^ref: ([^\r\n]+)')
      if ref then paths[#paths + 1] = dir .. '/' .. ref end
      local parts, remaining = { head, common }, #paths
      for i, path in ipairs(paths) do
        uv.fs_stat(path, function(_, stat)
          parts[i + 2] = stat and table.concat({ stat.ino, stat.size,
            stat.mtime.sec, stat.mtime.nsec, stat.ctime.sec, stat.ctime.nsec }, ':') or '-'
          remaining = remaining - 1
          if remaining == 0 then
            vim.schedule(function()
              repo.pending = false
              if not live(repo) then return end
              watch_paths(repo, paths, dir)
              local signature = table.concat(parts, '\0')
              local changed = repo.signature ~= nil and repo.signature ~= signature
              repo.signature = signature
              if changed then
                for _, callback in pairs(repo.listeners) do callback() end
              end
              if repo.again then repo.again = false; enqueue(repo) end
            end)
          end
        end)
      end
    end)
  end)
end

function M.subscribe(git_dir, callback)
  if not git_dir or git_dir == '' then return function() end end
  git_dir = vim.fs.normalize(git_dir)
  local repo = repositories[git_dir]
  if not repo then
    repo = { dir = git_dir, listeners = {}, handles = {} }
    repositories[git_dir] = repo
    watch_paths(repo, { git_dir .. '/HEAD' }, git_dir)
  end
  local key = {}
  repo.listeners[key] = callback
  check(repo)
  return function()
    repo.listeners[key] = nil
    if next(repo.listeners) or not live(repo) then return end
    repositories[git_dir] = nil
    for dir, handle in pairs(repo.handles) do repo.handles[dir] = nil; close(handle) end
    if repo.debounce then
      local timer = repo.debounce
      repo.debounce = nil
      close(timer)
    end
  end
end

return M
