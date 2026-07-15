local M = {}

local function cancelled_status()
  return {
    exitCode = 130,
    signal = 2,
  }
end

function M.finish(terminal, status)
  if not terminal or terminal.settled == true then
    return false
  end
  terminal.settled = true
  terminal.exit_status = status or cancelled_status()
  local waiters = terminal.waiters or {}
  terminal.waiters = {}
  for _, waiter in ipairs(waiters) do
    pcall(waiter, vim.deepcopy(terminal.exit_status))
  end
  return true
end

function M.release(session, terminal_id, opts)
  opts = opts or {}
  local terminals = session and session.terminals or nil
  local terminal = terminals and terminals[terminal_id] or nil
  if not terminal then
    return false
  end

  terminal.released = true
  if terminal.job_id and not terminal.exit_status then
    pcall(opts.jobstop or vim.fn.jobstop, terminal.job_id)
  end
  M.finish(terminal, opts.status or cancelled_status())
  terminals[terminal_id] = nil
  return true
end

function M.release_all(session, opts)
  local ids = vim.tbl_keys((session and session.terminals) or {})
  table.sort(ids)
  local released = 0
  for _, terminal_id in ipairs(ids) do
    if M.release(session, terminal_id, opts) then
      released = released + 1
    end
  end
  return released
end

return M
