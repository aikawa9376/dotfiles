local M = {}

function M.run()
  local Test = require("lazyagent.acp.worktree_test")
  assert(vim.deep_equal(Test.argv("cargo test", "/bin/sh", "-c"), { "/bin/sh", "-c", "cargo test" }), "test argv")
  local passed = Test.finish("cargo test", 100, { code = 0, stdout = "ok" }, 350)
  assert(passed.status == "passed" and passed.duration_ms == 250 and passed.output == "ok", "passed test result")
  local failed = Test.finish("make test", 0, { code = 2, stdout = "out", stderr = "err" }, 10)
  assert(failed.status == "failed" and failed.exit_code == 2 and failed.output == "out\nerr", "failed test result")
  assert(Test.status(passed) == "unknown", "legacy result without verification is unknown")
  passed.fingerprint = "before"
  assert(Test.status(passed, "before") == "passed", "matching workspace is passed")
  assert(Test.status(passed, "after") == "stale", "different workspace is stale")
  passed.verification_error = "capture failed"
  assert(Test.status(passed, "before") == "unknown", "verification errors do not certify a pass")
end

return M
