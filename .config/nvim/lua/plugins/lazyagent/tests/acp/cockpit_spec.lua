local M = {}

function M.run()
  local Cockpit = require("lazyagent.acp.cockpit")
  local lines, line_map = Cockpit.render({
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
  })
  local rendered = table.concat(lines, "\n")
  assert(rendered:find("## /tmp/project%-a"), "project A group")
  assert(rendered:find("## /tmp/project%-b"), "project B group")
  assert(rendered:find("%[active%] First · claude · model:opus · unread · changes:2"), "thread card columns")
  local mapped = {}
  for _, id in pairs(line_map) do mapped[id] = true end
  assert(mapped["thread-a"] and mapped["thread-b"], "thread line mappings")
end

return M
