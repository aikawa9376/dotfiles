local M = {}
local worker = vim.fs.dirname(debug.getinfo(1, "S").source:gsub("^@", "")) .. "/workspace_fingerprint_worker.lua"

-- Workspace scans run in a separate Neovim, never in cursor/preview callbacks.
function M.capture(cwd, callback)
  local ok, job = pcall(vim.system, {
    vim.v.progpath, "--headless", "--clean", "-u", "NONE", "-l", worker, cwd,
  }, { text = true, timeout = 7000 }, function(result)
    vim.schedule(function()
      local decoded, value = pcall(vim.json.decode, result.stdout or "")
      if result.code ~= 0 or not decoded or type(value) ~= "table" then
        callback(nil, "Workspace verification failed or timed out")
      else
        callback(value.fingerprint, value.error)
      end
    end)
  end)
  if not ok then vim.schedule(function() callback(nil, tostring(job)) end); return nil end
  return job
end

return M
