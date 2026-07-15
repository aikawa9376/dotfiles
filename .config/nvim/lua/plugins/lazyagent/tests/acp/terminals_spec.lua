local M = {}

local function assert_equal(expected, actual, label)
  if not vim.deep_equal(expected, actual) then
    error(string.format("%s: expected %s, got %s", label, vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

function M.run()
  local Terminals = require("lazyagent.acp.backend.terminals")
  local stopped = {}
  local completed = {}
  local session = {
    terminals = {
      second = {
        job_id = 22,
        waiters = {
          function(status) completed[#completed + 1] = { "second", status } end,
        },
      },
      first = {
        job_id = 11,
        waiters = {
          function(status) completed[#completed + 1] = { "first", status } end,
        },
      },
    },
  }

  local count = Terminals.release_all(session, {
    jobstop = function(job_id)
      stopped[#stopped + 1] = job_id
    end,
  })
  assert_equal(2, count, "released count")
  assert_equal({ 11, 22 }, stopped, "stable job stop order")
  assert_equal("first", completed[1][1], "stable waiter order")
  assert_equal({ exitCode = 130, signal = 2 }, completed[1][2], "cancelled exit status")
  assert_equal({}, session.terminals, "terminal table cleared")
  assert_equal(0, Terminals.release_all(session), "second release is inert")

  local terminal = { waiters = {} }
  assert_equal(true, Terminals.finish(terminal, { exitCode = 0, signal = vim.NIL }), "first finish")
  assert_equal(false, Terminals.finish(terminal, { exitCode = 1, signal = 1 }), "duplicate finish")
  assert_equal(0, terminal.exit_status.exitCode, "first status preserved")
end

return M
