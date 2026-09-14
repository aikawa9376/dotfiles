-- Recursive worktree notifications on Linux/macOS without polling or checktime.
local M = {}
local uv = vim.uv
local roots = {}
local limit = 4096
local schedule, scan
local function live(repo) return roots[repo.root] == repo end
local function close(handle) handle:stop(); handle:close() end

local function git(repo, args, stdin, callback)
  local argv = { 'git', '--no-optional-locks' }
  vim.list_extend(argv, args)
  local job
  job = vim.system(argv, { cwd = repo.root, stdin = stdin, timeout = 10000 }, function(result)
    vim.schedule(function()
      repo.jobs[job] = nil
      if live(repo) then callback(result) end
    end)
  end)
  repo.jobs[job] = true
end

local function watch(repo, dir, stat)
  local existing = repo.dirs[dir]
  local identity = tostring(stat.dev) .. ':' .. tostring(stat.ino)
  if existing and existing.identity == identity then return end
  if existing then close(existing.handle); repo.dirs[dir] = nil end
  local handle = uv.new_fs_event()
  if not handle then return end
  local ok = handle:start(dir, {}, function(err, filename)
    vim.schedule(function()
      if not live(repo) or not repo.dirs[dir] or repo.dirs[dir].handle ~= handle then return end
      if filename == '.git' or (filename and filename:match('^%.git/')) then return end
      if filename == '.gitignore' then repo.rescan = true end
      local path = filename and vim.fs.joinpath(dir, filename) or dir
      if err or not filename or repo.dirs[path] then
        repo.rescan = true
        schedule(repo)
      else
        uv.fs_lstat(path, function(_, info)
          vim.schedule(function()
            if not live(repo) then return end
            if info and info.type == 'directory' then repo.rescan = true end
            schedule(repo)
          end)
        end)
      end
    end)
  end)
  if ok then repo.dirs[dir] = { handle = handle, identity = identity }
  else handle:close() end
end

local function publish(repo)
  if not live(repo) then return end
  for _, callback in pairs(repo.listeners) do callback() end
end

schedule = function(repo)
  if not live(repo) or repo.timer then return end
  local timer = uv.new_timer()
  repo.timer = timer
  timer:start(300, 0, function()
    vim.schedule(function()
      if repo.timer ~= timer then return end
      repo.timer = nil
      timer:close()
      if not live(repo) then return end
      if repo.scanning then repo.changed_during_scan = true; return end
      if repo.rescan then scan(repo) else publish(repo) end
    end)
  end)
end

scan = function(repo)
  if repo.scanning or not live(repo) then return end
  repo.scanning, repo.rescan = true, false
  git(repo, { 'ls-files', '--cached', '-z' }, nil, function(result)
    if result.code ~= 0 then repo.scanning = false; publish(repo); return end
    local tracked = {}
    for path in (result.stdout or ''):gmatch('[^%z]+') do
      local dir = vim.fs.dirname(path)
      while dir and dir ~= '.' do tracked[dir] = true; dir = vim.fs.dirname(dir) end
    end
    local seen, count = {}, 0
    local function finish()
      for dir, item in pairs(repo.dirs) do
        if not seen[dir] then repo.dirs[dir] = nil; close(item.handle) end
      end
      repo.scanning = false
      publish(repo) -- Also covers edits made while discovering new directories.
      if repo.rescan or repo.changed_during_scan then
        repo.changed_during_scan = false
        schedule(repo)
      end
    end
    local visit
    visit = function(frontier)
      if not live(repo) then return end
      if #frontier == 0 then finish(); return end
      local children, remaining = {}, #frontier
      local function done()
        remaining = remaining - 1
        if remaining ~= 0 then return end
        if #children == 0 then finish(); return end
        local input = {}
        for _, relative in ipairs(children) do input[#input + 1] = relative .. '/' end
        git(repo, { 'check-ignore', '--no-index', '-z', '--stdin' }, table.concat(input, '\0') .. '\0', function(ignored)
          if ignored.code ~= 0 and ignored.code ~= 1 then finish(); return end
          local excluded = {}
          for path in (ignored.stdout or ''):gmatch('[^%z]+') do excluded[path:gsub('/$', '')] = true end
          local next_dirs = {}
          for _, relative in ipairs(children) do
            if not excluded[relative] or tracked[relative] then
              if count + #next_dirs < limit then next_dirs[#next_dirs + 1] = relative
              elseif not repo.warned then
                repo.warned = true
                vim.notify('Git status: directory watch limit reached; remaining paths refresh on focus', vim.log.levels.WARN)
              end
            end
          end
          visit(next_dirs)
        end)
      end
      for _, relative in ipairs(frontier) do
        local dir = relative == '' and repo.root or vim.fs.joinpath(repo.root, relative)
        count = count + 1
        uv.fs_lstat(dir, function(_, stat)
          if not stat or stat.type ~= 'directory' then vim.schedule(function() if live(repo) then done() end end); return end
          uv.fs_scandir(dir, function(_, entries)
            local found = {}
            if entries then
              while true do
                local name, kind = uv.fs_scandir_next(entries)
                if not name then break end
                if kind == 'directory' and name ~= '.git' then
                  found[#found + 1] = relative == '' and name or relative .. '/' .. name
                end
              end
            end
            vim.schedule(function()
              if not live(repo) then return end
              seen[dir] = true
              watch(repo, dir, stat)
              vim.list_extend(children, found)
              done()
            end)
          end)
        end)
      end
    end
    visit({ '' })
  end)
end

function M.refresh(root)
  local repo = roots[vim.fs.normalize(root)]
  if repo then repo.rescan = true; schedule(repo) end
end

function M.subscribe(root, callback)
  root = vim.fs.normalize(root)
  local repo = roots[root]
  if not repo then
    repo = { root = root, listeners = {}, dirs = {}, jobs = {} }
    roots[root] = repo
  end
  local key = {}
  repo.listeners[key] = callback
  if not next(repo.dirs) then scan(repo) end
  return function()
    repo.listeners[key] = nil
    if not live(repo) or next(repo.listeners) then return end
    roots[root] = nil
    if repo.timer then local timer = repo.timer; repo.timer = nil; close(timer) end
    for dir, item in pairs(repo.dirs) do repo.dirs[dir] = nil; close(item.handle) end
    for job in pairs(repo.jobs) do pcall(job.kill, job, 15) end
  end
end

return M
