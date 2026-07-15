local M = {}

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
