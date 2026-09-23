-- Revalidate on editor events, including worktree edits that never touch .git.
local M = {}

function M.new(root, changed)
  local active, pending, queued = true, false, false
  local signature, job
  local request
  local function finish(value)
    if not active then return end
    pending, job = false, nil
    if value then
      local different = signature ~= nil and signature ~= value
      signature = value
      if different then changed() end
    end
    if queued then queued = false; request() end
  end
  request = function()
    if not active then return end
    if pending then queued = true; return end
    pending = true
    local ok, started = pcall(vim.system, { 'git', '--no-optional-locks', 'status', '--porcelain=v2',
      '--branch', '-z', '--untracked-files=all' }, { cwd = root, timeout = 5000 }, function(result)
      vim.schedule(function()
        if not active then return end
        job = nil
        if result.code ~= 0 then finish(nil); return end
        local output, paths = result.stdout or '', {}
        local skip = false
        for record in output:gmatch('[^%z]+') do
          if skip then skip = false
          else
            local kind = record:sub(1, 1)
            local fields = ({ ['1'] = 8, ['2'] = 9, u = 10, ['?'] = 1 })[kind]
            if fields then
              local position = 1
              for _ = 1, fields do
                local space = record:find(' ', position, true)
                if not space then position = nil; break end
                position = space + 1
              end
              if position then paths[#paths + 1] = record:sub(position) end
            end
            skip = kind == '2'
          end
        end
        local remaining, parts = #paths, { output }
        if remaining == 0 then finish(output); return end
        for i, path in ipairs(paths) do
          vim.uv.fs_lstat(root .. '/' .. path, function(_, stat)
            parts[i + 1] = stat and table.concat({ stat.ino, stat.size,
              stat.mtime.sec, stat.mtime.nsec, stat.ctime.sec, stat.ctime.nsec }, ':') or '-'
            remaining = remaining - 1
            if remaining == 0 then
              vim.schedule(function() finish(table.concat(parts, '\0')) end)
            end
          end)
        end
      end)
    end)
    if ok then job = started else finish(nil) end
  end
  local scheduled = false
  return {
    check = function()
      if not active or scheduled then return end
      scheduled = true
      vim.schedule(function()
        scheduled = false
        request()
      end)
    end,
    stop = function()
      active, queued = false, false
      if job then pcall(job.kill, job, 15); job = nil end
    end,
  }
end

return M
