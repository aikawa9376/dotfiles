local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source))))
vim.opt.runtimepath:prepend(root)
local uv = vim.uv or vim.loop

local ok, value = pcall(function()
  if not arg[1] or vim.fn.isdirectory(arg[1]) ~= 1 then error("Workspace is unavailable") end
  local records = {}
  local snapshot = require("lazyagent.acp.workspace_snapshot").capture(arg[1], {
    timeout_ms = 5000,
    stat = function(path)
      local stat = uv.fs_lstat(path)
      if stat then
        records[path] = {
          path, stat.type, stat.size, stat.mode,
          stat.mtime.sec, stat.mtime.nsec, stat.ctime.sec, stat.ctime.nsec,
        }
      else
        records[path] = { path, "missing" }
      end
      return stat
    end,
  })
  if snapshot.truncated then error("Workspace verification exceeded the file limit") end
  if snapshot.git_error then error(snapshot.git_error) end
  local files = {}
  for _, path in ipairs(vim.fn.sort(vim.tbl_keys(records))) do files[#files + 1] = records[path] end
  local index = ""
  if snapshot.vcs.kind == "git" then
    local staged = vim.system({ "git", "-C", snapshot.root, "ls-files", "--stage", "-z" }):wait(1000)
    if staged.code ~= 0 then error("Could not verify the Git index") end
    index = staged.stdout or ""
  end
  return { fingerprint = vim.fn.sha256(vim.json.encode({
    snapshot.root, snapshot.vcs.kind, snapshot.vcs.head or "", index, files,
  })) }
end)
io.stdout:write(vim.json.encode(ok and value or { error = tostring(value) }))
