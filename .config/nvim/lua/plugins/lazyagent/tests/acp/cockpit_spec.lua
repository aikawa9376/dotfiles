local M = {}

function M.run()
  local Cockpit = require("lazyagent.acp.cockpit")
  local threads = {
    {
      thread_id = "thread-b", title = "Second", provider_id = "codex", cwd = "/tmp/project-b",
      status = "archived", updated_at = "2026-07-14T00:00:00Z", change_journal = { turns = {} },
    },
    {
      thread_id = "thread-a", title = "First", provider_id = "claude", cwd = "/tmp/project-a",
      status = "active", unread = true, model = "opus", updated_at = "2026-07-15T00:00:00Z",
      change_journal = { turns = { { changes = {
        { path = "one.lua" }, { path = "one.lua" }, { new_path = "two.lua" },
      } } } },
    },
  }
  local lines, line_map = Cockpit.render(threads, {
    ["thread-a"] = {
      acp_ready = true,
      acp_busy = true,
      acp_usage_stats = { cumulative = { total_tokens = 1234, cost = 0.125 } },
      acp_model_catalog = { currentModelId = "runtime-opus" },
    },
  })
  local rendered = table.concat(lines, "\n")
  assert(rendered:find("## /tmp/project%-a"), "project A group")
  assert(rendered:find("## /tmp/project%-b"), "project B group")
  assert(rendered:find("%[running%] First · claude · model:runtime%-opus · unread · usage:1234tok/%$0%.1250 · changes:2"), "thread card columns")
  local permission_lines = Cockpit.render(threads, {
    ["thread-a"] = { acp_ready = true, acp_client_debug = { pending_permissions = 1 } },
  })
  assert(table.concat(permission_lines, "\n"):find("%[permission%] First"), "permission common status")
  local mapped = {}
  for _, id in pairs(line_map) do mapped[id] = true end
  assert(mapped["thread-a"] and mapped["thread-b"], "thread line mappings")
  local filtered = Cockpit.filter(threads, "CLAUDE")
  assert(#filtered == 1 and filtered[1].thread_id == "thread-a", "cockpit case-insensitive filter")
end

return M
