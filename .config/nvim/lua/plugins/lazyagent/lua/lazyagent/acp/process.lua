local M = {}
local uv = vim.uv or vim.loop

function M.inspect(pid)
  pid = tonumber(pid)
  if not pid or pid <= 0 then return { alive = false } end
  local ok, result, err, code = pcall(uv.kill, pid, 0)
  if not ok then return { error = tostring(result) } end
  if code == "ESRCH" then return { alive = false } end
  local info = { alive = result == 0 and true or nil, error = err or code }
  -- Linux kill(0) also succeeds for zombies. Start time distinguishes a saved
  -- agent PID from a later, unrelated process that reused that number.
  local fd = uv.fs_open("/proc/" .. tostring(pid) .. "/stat", "r", 0)
  if fd then
    local stat = uv.fs_read(fd, 4096, 0)
    uv.fs_close(fd)
    local tail = stat and stat:match("^%d+ %(.+%) (.*)$")
    local fields = tail and vim.split(tail, " ", { trimempty = true }) or {}
    if fields[1] == "Z" or fields[1] == "X" then info.alive = false end
    if fields[20] then info.identity = tostring(pid) .. ":" .. fields[20] end
  end
  return info
end

return M
