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
  assert(rendered:find("%[running%]%s+claude · model:runtime%-opus · unread · usage:1234tok/%$0%.1250 · changes:2 · First"), "thread card columns")
  assert(rendered:find("persisted threads: running = live process"), "cockpit lifecycle legend")
  local permission_lines = Cockpit.render(threads, {
    ["thread-a"] = { acp_ready = true, acp_client_debug = { pending_permissions = 1 } },
  })
  assert(table.concat(permission_lines, "\n"):find("%[permission%]%s+claude.- · First"), "permission common status")
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
  local compact_lines = Cockpit.render(narrow_threads, {}, { width = 160 })
  local compact_rendered = table.concat(compact_lines, "\n")
  assert(compact_rendered:find("%- %[active%]", 1) or compact_rendered:find("%- %[archived%]", 1), "unpinned row has compact prefix")
  assert(not compact_rendered:find("deliberately much too long for a single cockpit line", 1, true), "prompt has a compact maximum width")
  local filtered = Cockpit.filter(threads, "CLAUDE")
  assert(#filtered == 1 and filtered[1].thread_id == "thread-a", "cockpit case-insensitive filter")
  local without_empty = Cockpit.filter({
    { thread_id = "empty", title = "Codex", provider_id = "Codex", status = "closed", transcript_path = "" },
    { thread_id = "prompted", title = "Real prompt", provider_id = "Codex", status = "closed", transcript_path = "" },
  }, "")
  assert(#without_empty == 1 and without_empty[1].thread_id == "prompted", "closed threads without prompts are hidden")

  local transcript_path = vim.fn.tempname() .. "-cockpit-transcript.log"
  vim.fn.writefile({
    "─ 󰋽 System", " ready", "", "─ 󰍩 User ─────────", " instant mix", "", "─ 󰭹 Assistant ─────", " done",
  }, transcript_path)
  local transcript_thread = {
    thread_id = "transcript", title = "Codex", provider_id = "Codex", status = "closed", transcript_path = transcript_path,
  }
  assert(Cockpit.prompt_title(transcript_thread) == "instant mix", "first transcript prompt is used as title")
  assert(#Cockpit.filter({ transcript_thread }, "") == 1, "transcript prompt keeps generic provider title thread")

  local empty_path = vim.fn.tempname() .. "-cockpit-empty.log"
  vim.fn.writefile({ "─ 󰋽 System", " ready" }, empty_path)
  local deleted = {}
  local kept, removed = Cockpit.prune_empty({
    delete_thread = function(thread_id)
      deleted[thread_id] = true
      return true
    end,
  }, {
    transcript_thread,
    { thread_id = "empty-old", title = "Codex", provider_id = "Codex", status = "closed", transcript_path = empty_path },
  })
  assert(#kept == 1 and kept[1].thread_id == "transcript" and removed == 1, "historical empty thread pruning")
  assert(deleted["empty-old"] == true and vim.fn.filereadable(empty_path) == 0, "empty manifest record and transcript removal")
  vim.fn.delete(transcript_path)

  local aligned_lines = Cockpit.render({
    { thread_id = "idle", title = "Idle prompt", provider_id = "Codex", cwd = "/tmp/aligned", status = "active" },
    { thread_id = "run", title = "Running prompt", provider_id = "Codex", cwd = "/tmp/aligned", status = "active" },
  }, {
    idle = { acp_ready = true },
    run = { acp_ready = true, acp_busy = true },
  }, { width = 100 })
  local provider_columns = {}
  for _, line in ipairs(aligned_lines) do
    if line:match("^%- ") then provider_columns[#provider_columns + 1] = assert(line:find("Codex", 1, true)) end
  end
  assert(#provider_columns == 2 and provider_columns[1] == provider_columns[2], "status column alignment")

  local conflicts = Cockpit.conflicts({
    { thread_id = "one", cwd = "/shared", status = "active", change_journal = { turns = { { changes = { { path = "same.lua" } } } } } },
    { thread_id = "two", cwd = "/shared", status = "active", change_journal = { turns = { { changes = { { path = "same.lua" } } } } } },
    { thread_id = "isolated", cwd = "/worktree", status = "active", change_journal = { turns = { { changes = { { path = "same.lua" } } } } } },
  })
  assert(conflicts.one["same.lua"] and conflicts.two["same.lua"], "shared root conflict")
  assert(conflicts.isolated == nil, "worktree conflict isolation")
end

return M
