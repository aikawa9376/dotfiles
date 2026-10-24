local M = {}
function M.run()
  local Query = require("lazyagent.acp.cockpit_query")
  local function matches(query, attrs) return Query.matches(assert(Query.compile(query)), attrs) end
  assert(matches("parser auth", { text = "Fix parser auth callback" }), "plain phrase retains literal substring behavior")
  assert(not matches("parser auth", { text = "parser changed auth" }), "plain phrases do not silently become AND terms")
  assert(matches("status:running,idle unread:true -provider:claude auth", {
    status = "running", unread = true, provider = "Codex", text = "Fix auth" }), "conditions AND together with enum alternatives and negation")
  assert(not matches("status:running", { status = "not_running" }), "status is an exact value")
  assert(matches('workspace:"/tmp/My Repo" activity:"Run tests"', { workspace = "/tmp/My Repo", activity = "Tool: Run tests" }), "quoted field values")
  assert(matches('"status:running"', { text = "literal status:running example" }), "quoted whole token is literal")
  assert(matches('"-deprecated"', { text = "flag -deprecated" }), "quoted leading dash remains literal")
  assert(matches('-"old API" new', { text = "new API" }), "negative phrase")
  assert(matches("don't", { text = "don't stop" }), "apostrophes in normal text are literal")
  assert(matches("https://example.test/a:b", { text = "See https://example.test/a:b" }), "URLs and unknown field names remain literal")
  assert(matches('activity:"read \\"file\\""', { activity = 'read "file"' }), "escaped quotes")
  assert(matches("workspace:current", { current_workspace = true }) and not matches("workspace:current", { current_workspace = false }), "dynamic workspace restriction")
  assert(not Query.compile('status:"running'), "unclosed quote rejected")
  assert(not Query.compile("status:") and not Query.compile("unread:maybe"), "invalid known conditions rejected")
  local Cockpit = require("lazyagent.acp.cockpit")
  local threads = {
    { thread_id = "current", title = "Auth callback", provider_id = "Codex", model = "gpt-model", cwd = "/tmp/repo", status = "active", unread = true },
    { thread_id = "quiet", title = "Other auth", provider_id = "Claude", cwd = "/tmp/other", status = "closed", metadata = { cockpit_pinned = true } },
  }
  local runtime = { current = { acp_ready = true, acp_busy = true } }
  local opts = { current_root = "/tmp/repo/" }
  assert(#Cockpit.filter(threads, "workspace:current status:running provider:codex unread:true", runtime, opts) == 1, "filter uses displayed runtime state and normalized current root")
  assert(#Cockpit.filter(threads, "status:active", runtime, opts) == 0, "raw persisted active does not override displayed status")
  assert(#Cockpit.filter(threads, "pinned:true live:false tracked:false", runtime, opts) == 1, "boolean fields")
  assert(#Cockpit.filter(threads, "review:off test:none", runtime, opts) == 2, "review and test projections")
  threads[1].metadata = { cockpit_completion = { id = "new" } }
  assert(#Cockpit.filter(threads, "attention:true", runtime, opts) == 1, "attention condition uses actual reasons")
  local empty, err = Cockpit.filter(threads, "attention:invalid", runtime, opts)
  assert(#empty == 0 and err, "invalid public filter returns an error without broad matches")
end
return M
