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
  local lines, line_map, highlights = Cockpit.render(threads, {
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
  assert(rendered:find("persisted threads: running = live process"), "cockpit lifecycle legend")
  local permission_lines = Cockpit.render(threads, {
    ["thread-a"] = { acp_ready = true, acp_client_debug = { pending_permissions = 1 } },
  })
  assert(table.concat(permission_lines, "\n"):find("%[permission%] First"), "permission common status")
  local mapped = {}
  for _, id in pairs(line_map) do mapped[id] = true end
  assert(mapped["thread-a"] and mapped["thread-b"], "thread line mappings")
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  Cockpit.apply_highlights(bufnr, highlights)
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, vim.api.nvim_create_namespace("LazyAgentACPCockpit"), 0, -1, {})
  assert(#marks >= 10, "cockpit semantic highlights")
  vim.api.nvim_buf_delete(bufnr, { force = true })

  local narrow_threads = vim.deepcopy(threads)
  narrow_threads[2].title = "This is the first prompt and it is deliberately much too long for a single cockpit line"
  local narrow_lines = Cockpit.render(narrow_threads, {}, { width = 64 })
  local narrow_rendered = table.concat(narrow_lines, "\n")
  assert(narrow_rendered:find("…", 1, true), "long first prompt is truncated")
  for _, line in ipairs(narrow_lines) do
    if line:match("^%- ") then
      assert(vim.fn.strdisplaywidth(line) <= 64, "thread card fits requested width")
    end
  end
  local filtered = Cockpit.filter(threads, "CLAUDE")
  assert(#filtered == 1 and filtered[1].thread_id == "thread-a", "cockpit case-insensitive filter")

  local conflicts = Cockpit.conflicts({
    { thread_id = "one", cwd = "/shared", status = "active", change_journal = { turns = { { changes = { { path = "same.lua" } } } } } },
    { thread_id = "two", cwd = "/shared", status = "active", change_journal = { turns = { { changes = { { path = "same.lua" } } } } } },
    { thread_id = "isolated", cwd = "/worktree", status = "active", change_journal = { turns = { { changes = { { path = "same.lua" } } } } } },
  })
  assert(conflicts.one["same.lua"] and conflicts.two["same.lua"], "shared root conflict")
  assert(conflicts.isolated == nil, "worktree conflict isolation")
end

return M
