-- File identity shared by status invalidation and source/statistics caches.
local M = {}

function M.stat_key(stat)
  if not stat then return '-' end
  return table.concat({ stat.type, stat.dev, stat.ino, stat.mode, stat.size,
    stat.mtime.sec, stat.mtime.nsec, stat.ctime.sec, stat.ctime.nsec }, ':')
end

function M.fingerprint(path)
  return M.stat_key(path and vim.uv.fs_lstat(path))
end

return M
