local M = {}

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run()
  local Guard = require("lazyagent.acp.backend.read_only_guard")
  local session = {}
  assert_equal(Guard.write_error(session), nil, "writes are unrestricted without a guard")
  assert(Guard.set(session, "review-1", true, "review is read-only"))
  assert_equal(Guard.reason(session), "review is read-only", "guard reason")
  assert(Guard.write_error(session).message:find("write rejected", 1, true), "guard rejects file writes")

  assert_equal(Guard.terminal_error(session, { command = "git", args = { "diff", "a", "b" } }), nil,
    "git diff is allowed")
  assert_equal(Guard.terminal_error(session, { command = "/usr/bin/git", args = { "-C", "/repo", "show", "HEAD" } }), nil,
    "read-only git command with a cwd is allowed")
  assert(Guard.terminal_error(session, { command = "git", args = { "diff", "--output=result.patch" } }),
    "git diff output files are rejected")
  assert_equal(Guard.terminal_error(session, { command = "rg", args = { "needle", "." } }), nil,
    "ripgrep is allowed")
  assert(Guard.terminal_error(session, { command = "rg", args = { "--pre", "mutating-command", "needle" } }),
    "ripgrep preprocessors are rejected")
  assert(Guard.terminal_error(session, { command = "sh", args = { "-c", "touch changed" } }),
    "shell commands are rejected")
  assert(Guard.terminal_error(session, { command = "git", args = { "checkout", "HEAD" } }),
    "mutating Git commands are rejected")
  assert(Guard.terminal_error(session, { command = "git", args = { "grep", "-O", "editor", "needle" } }),
    "Git commands cannot launch a pager or editor")
  assert(Guard.terminal_error(session, { command = "git", args = { "-c", "alias.diff=!touch changed", "diff" } }),
    "Git config overrides are rejected")
  assert(Guard.terminal_error(session, { command = "git", args = { "diff" }, env = { { name = "PATH", value = "/tmp" } } }),
    "terminal environment overrides are rejected")

  assert(Guard.set(session, "review-2", true, "another review is read-only"))
  assert(Guard.set(session, "review-1", false))
  assert_equal(Guard.reason(session), "another review is read-only", "guards are independently owned")
  assert(Guard.set(session, "review-2", false))
  assert_equal(Guard.reason(session), nil, "last owner releases the guard")
end

return M
