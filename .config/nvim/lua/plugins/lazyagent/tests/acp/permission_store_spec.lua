local M = {}

function M.run()
  local Store = require("lazyagent.acp.permission_store")
  local base = vim.fn.tempname()
  local opts = { base_dir = base }
  local session = { agent_name = "Codex::thread", provider_id = "Codex", thread_id = "thread", root_dir = "/project" }
  local tool = { toolCallId = "tool-1", toolName = "write_file", kind = "edit", title = "Edit file" }
  local option = { optionId = "allow", kind = "allow_once" }
  local labels, choices = Store.choices({ option, { optionId = "reject", kind = "reject_once", name = "Reject" } })
  assert(#labels == 8 and choices[3].scope == "session" and choices[5].scope == "global", "scoped permission choices")
  local session_rule = Store.rule(session, tool, option, "session", "/project/a.lua")
  assert(Store.remember(session, "session", session_rule, opts), "remember session permission")
  assert(Store.remember(session, "project", Store.rule(session, tool, option, "project", "/project/b.lua"), opts),
    "remember project permission")
  assert(Store.remember(session, "global", Store.rule(session, tool, option, "global", "/project/c.lua"), opts),
    "remember global permission")
  local rules = Store.rules(session, opts)
  assert(#rules == 3 and rules[1].scope == "session" and rules[2].scope == "project" and rules[3].scope == "global",
    "permission scopes load in priority order")
  local audit_path = assert(Store.audit(session, tool, { outcome = "selected", optionId = "allow" }, {
    source = "remembered", scope = "project", path = "/project/b.lua",
  }, opts))
  local audit = vim.json.decode(vim.fn.readfile(audit_path)[1])
  assert(audit.source == "remembered" and audit.scope == "project" and audit.option_id == "allow", "permission audit")
  assert(audit.title == nil and audit.content == nil, "permission audit excludes tool body")
  vim.fn.delete(base, "rf")
end

return M
