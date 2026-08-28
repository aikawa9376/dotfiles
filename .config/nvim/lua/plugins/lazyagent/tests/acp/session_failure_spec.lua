local M = {}

local function assert_equal(expected, actual, label)
  if not vim.deep_equal(expected, actual) then
    error(string.format("%s: expected %s, got %s", label, vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local function carrier(record)
  return { _meta = { jetbrains = { air = { version = 1, sessionFailure = record } } } }
end

function M.run()
  local Failure = require("lazyagent.acp.session_failure")
  local owner = {}
  local first, status = Failure.apply(owner, carrier({
    id = "turn-1:error",
    revision = 1,
    category = "connection",
    severity = "warning",
    title = "Retrying connection",
    actions = { "retry", "retry", "" },
  }))
  assert_equal("created", status, "first failure status")
  assert_equal({ "retry" }, first.actions, "failure actions are normalized")
  assert_equal("turn-1:error", owner.active_session_failure.id, "failure becomes active")

  local stale, stale_status = Failure.apply(owner, carrier({
    id = "turn-1:error", revision = 1, category = "service", severity = "error", title = "stale", actions = {},
  }))
  assert_equal("ignored", stale_status, "same revision is ignored")
  assert_equal("Retrying connection", stale.title, "same revision does not replace state")

  local updated, updated_status = Failure.apply(owner, carrier({
    id = "turn-1:error",
    revision = 2,
    category = "connection",
    severity = "error",
    title = "Connection lost",
    details = "Start a fresh runtime.",
    actions = { "new_session" },
  }))
  assert_equal("updated", updated_status, "higher revision updates incident")
  assert(Failure.render(updated):find("Connection lost", 1, true), "failure rendering")
  assert_equal(true, Failure.resolve(owner, updated.id), "active failure resolves")
  assert_equal(nil, owner.active_session_failure, "history remains without an active failure")
  assert_equal("Connection lost", owner.session_failures[updated.id].title, "resolved failure remains durable")
  assert_equal(nil, Failure.extract(carrier({ id = "bad", revision = 0, severity = "error", title = "bad" })),
    "invalid failure is rejected")
  assert_equal(nil, Failure.extract(carrier({
    id = "bad", revision = 1.5, category = "service", severity = "error", title = "bad",
  })), "fractional revision is rejected")
end

return M
