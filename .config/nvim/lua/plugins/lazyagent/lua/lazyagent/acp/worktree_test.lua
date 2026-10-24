local M = {}
local Fingerprint = require("lazyagent.acp.workspace_fingerprint")
local active = {}

function M.status(result, fingerprint)
  if not result then return "none" end
  if result.status == "running" then return "running" end
  if result.stale == true then return "stale" end
  if type(result.verification_error) == "string" then return "unknown" end
  if type(result.fingerprint) ~= "string" or type(fingerprint) ~= "string" then return "unknown" end
  return result.fingerprint == fingerprint and result.status or "stale"
end

function M.run(backend, thread, command, changed)
  local id = thread.thread_id
  if active[id] then return nil, "A test is already running for this thread" end
  local argv, err = M.argv(command)
  if not argv then return nil, err end
  local run_id = tostring((vim.uv or vim.loop).hrtime())
  local function save(result, expected)
    return backend.update_thread(id, { metadata = { test_result = result } }, {
      expected_test_run_id = expected,
    })
  end
  local saved, save_err = save({
    command = command, status = "running", run_id = run_id,
    fingerprint = vim.NIL, stale = false, output = "", verification_error = vim.NIL,
  })
  if not saved then return nil, save_err end
  active[id] = true
  if changed then changed() end
  Fingerprint.capture(thread.cwd, function(before, before_err)
    local started = (vim.uv or vim.loop).hrtime() / 1000000
    local function finish(result)
      local finished = (vim.uv or vim.loop).hrtime() / 1000000
      Fingerprint.capture(thread.cwd, function(after, after_err)
        active[id] = nil
        local report = M.finish(command, started, result, finished)
        report.run_id = run_id
        report.fingerprint = before or vim.NIL
        report.stale = before ~= nil and after ~= nil and before ~= after
        report.verification_error = before_err or after_err or vim.NIL
        save(report, run_id)
        if changed then changed() end
      end)
    end
    local launched, launch_err = pcall(vim.system, argv, { cwd = thread.cwd, text = true }, function(result)
      vim.schedule(function() finish(result) end)
    end)
    if not launched then finish({ code = -1, stderr = tostring(launch_err) }) end
  end)
  return true
end

function M.argv(command, shell, shellcmdflag)
  command = tostring(command or "")
  if command == "" then return nil, "test command is required" end
  return { shell or vim.o.shell, shellcmdflag or vim.o.shellcmdflag, command }
end

function M.finish(command, started_ms, result, finished_ms)
  result = result or {}
  local output = tostring(result.stdout or "")
  local stderr = tostring(result.stderr or "")
  if stderr ~= "" then output = output ~= "" and (output .. "\n" .. stderr) or stderr end
  local limit = 12000
  if #output > limit then output = "[earlier output truncated]\n" .. output:sub(#output - limit + 1) end
  return {
    command = command,
    status = tonumber(result.code) == 0 and "passed" or "failed",
    exit_code = tonumber(result.code),
    signal = result.signal,
    duration_ms = math.max(0, (tonumber(finished_ms) or 0) - (tonumber(started_ms) or 0)),
    finished_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    output = output,
  }
end

return M
