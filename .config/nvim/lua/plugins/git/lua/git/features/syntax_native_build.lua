-- Build the standard-library-only worker without Cargo or a blocking editor wait.
local M = {}

local function platform()
  local uname = vim.uv.os_uname()
  local os = uname.sysname:lower()
  local arch = uname.machine:lower()
  if os == 'windows_nt' then os = 'windows' end
  if arch == 'x86_64' or arch == 'amd64' then arch = 'x64'
  elseif arch == 'aarch64' then arch = 'arm64' end
  return os .. '-' .. arch, os == 'windows' and '.exe' or ''
end

local function signature(stat)
  return stat and table.concat({ stat.size, stat.mtime.sec, stat.mtime.nsec }, ':') or nil
end

local function older(binary, source)
  return binary.mtime.sec < source.mtime.sec
    or (binary.mtime.sec == source.mtime.sec and binary.mtime.nsec < source.mtime.nsec)
end

function M.new(source, bin_dir)
  local tag, suffix = platform()
  local self = { path = vim.fs.normalize(bin_dir .. '/' .. tag .. '/git-syntax-search' .. suffix),
    building = false }
  local attempted

  function self.command()
    local source_stat = vim.uv.fs_stat(source)
    local binary_stat = vim.uv.fs_stat(self.path)
    if binary_stat and vim.fn.executable(self.path) == 1
      and (not source_stat or not older(binary_stat, source_stat)) then
      return self.path
    end
    local revision = signature(source_stat)
    if self.building or not revision or attempted == revision or vim.fn.executable('rustc') ~= 1 then
      return nil
    end

    attempted, self.error = revision, nil
    local dir = vim.fs.dirname(self.path)
    local ok, err = pcall(vim.fn.mkdir, dir, 'p')
    if not ok then self.error = tostring(err); return nil end
    -- Separate outputs per editor; publish only complete, current-source binaries.
    local output = self.path .. '.tmp-' .. vim.uv.os_getpid() .. '-' .. tostring(vim.uv.hrtime())
    self.building = true
    local function finish(result)
      self.building = false
      if result.code == 0 and signature(vim.uv.fs_stat(source)) == revision then
        local renamed, rename_err = vim.uv.fs_rename(output, self.path)
        if renamed then attempted = nil; return end
        self.error = tostring(rename_err)
      elseif result.code ~= 0 then
        self.error = result.stderr or 'Rust worker build failed'
      end
      vim.uv.fs_unlink(output)
    end
    ok, err = pcall(vim.system, { 'rustc', '--edition=2021', '--crate-name', 'git_syntax_search',
      '-C', 'opt-level=3', '-C', 'lto=yes', '-C', 'codegen-units=1', '-C', 'panic=abort',
      '-C', 'strip=symbols', source, '-o', output }, { text = true }, function(result)
      vim.schedule(function() finish(result) end)
    end)
    if not ok then finish({ code = -1, stderr = tostring(err) }) end
    return nil
  end

  return self
end

return M
