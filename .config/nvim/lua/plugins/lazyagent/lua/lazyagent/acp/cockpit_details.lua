local M = {}
local Cockpit = require("lazyagent.acp.cockpit")
local Review = require("lazyagent.acp.cockpit_review")
local Activity = require("lazyagent.acp.cockpit_activity")

local function text(value)
  if value == vim.NIL then return "" end
  if type(value) == "table" then value = value.text or value.title or value.objective or vim.inspect(value) end
  return vim.trim(tostring(value or "")):gsub("%s+", " ")
end

function M.render(thread, runtime, section, opts)
  local supplied_runtime = runtime
  runtime, opts = runtime or {}, opts or {}
  local lines = {
    "# " .. tostring(thread.provider_id or "Agent") .. " · " .. text(Cockpit.prompt_title(thread) or thread.thread_id),
    "", "[Overview] [Changes] [Tests] [Queue] [Since check] · <Tab> next · K latest response",
    "C changes · gC compare since check · Q queue · A permission · t test · w review tracking · V since check · u mark checked", "",
  }
  local function add(line) lines[#lines + 1] = line end
  if section == "since" then
    local since = Cockpit.since(thread, opts)
    add("## Since last check")
    if not since.established then
      add("No checkpoint yet. Press u to mark the current recorded history checked.")
    else
      local seen = thread.metadata.cockpit_observation
      add("Checked: " .. text(seen.observed_at))
      add(string.format("%d new turn(s) · %d newly completed · %d changed file(s)", since.new_turns, since.completed_turns, #since.files))
      add(string.format("%d tool event(s) · %d file/buffer event(s) · %d review update(s)", since.tool_events, since.file_events, since.review_updates))
      add("Test result: " .. (since.test_changed and "updated" or "unchanged"))
      if since.history_gap then add("Recorded history was replaced or shortened; some earlier changes are unavailable.") end
      if not since.changed then add("No recorded changes since this checkpoint.") end
      for _, path in ipairs(since.files) do add("- " .. text(path)) end
      add(""); add("gC compares recorded code since check. C opens changes review. u updates this checkpoint without approving changes.")
    end
  elseif section == "changes" then
    add("## Changes")
    local review = Review.summary(thread, {
      fingerprint = opts.fingerprints and opts.fingerprints[thread.cwd],
      fingerprint_pending = opts.fingerprint_pending and opts.fingerprint_pending[thread.cwd],
      busy = runtime.acp_busy or runtime.acp_preparing_prompt,
    })
    local review_state = Cockpit.review(thread, supplied_runtime, opts).state
    add("Review: " .. review_state .. (review_state == "off" and " · w to enable tracking" or ""))
    add(string.format("Latest changed turn: %d approved · %d rejected · %d pending · %d user note(s)",
      review.counts.approved, review.counts.rejected, review.counts.pending, review.counts.notes))
    add(string.format("Hunk decisions: %d/%d", review.counts.hunks_decided, review.counts.hunks_total))
    local turns = thread.change_journal and thread.change_journal.turns or {}
    local turn = turns[#turns]
    add("Turn: " .. text(turn and turn.turn_id or "No recorded turn"))
    for _, change in ipairs(turn and turn.changes or {}) do
      add("- " .. text(change.operation or "modified") .. " " .. text(change.path or change.new_path or change.old_path))
    end
    if not turn or #(turn.changes or {}) == 0 then add("No recorded changes in the latest turn.") end
    add(""); add("C opens the existing changes/review UI for this thread.")
  elseif section == "tests" then
    add("## Tests · " .. Cockpit.test_status(thread, opts))
    local result = thread.metadata and thread.metadata.test_result
    if result then
      add("Command: " .. text(result.command))
      add("Last result: " .. text(result.status) .. " · exit " .. text(result.exit_code))
      add("Finished: " .. text(result.finished_at) .. " · duration " .. text(result.duration_ms) .. "ms")
      if type(result.verification_error) == "string" then add("Verification: " .. text(result.verification_error)) end
      add(""); add("Output:")
      local output = vim.split(tostring(result.output or ""), "\n", { plain = true })
      for index = math.max(1, #output - 19), #output do add("    " .. output[index]) end
    else
      add("No test has been run. Press t to run one.")
    end
  elseif section == "queue" then
    add("## Prompt queue")
    local queue = runtime.acp_prompt_queue or {}
    for _, item in ipairs(queue) do add("- " .. text(item.id) .. " · " .. text(item.text)) end
    if #queue == 0 then add("No queued prompts.") end
    add(""); add("Q opens the existing queue editor. i sends another prompt.")
  else
    add("## Overview")
    add("State: " .. Cockpit.thread_status(thread, runtime, opts))
    add("Workspace: " .. text(thread.cwd))
    add("Ref: " .. tostring(Cockpit.agent_ref(thread)))
    local review_state = Cockpit.review(thread, supplied_runtime, opts).state
    add("Review: " .. review_state .. (review_state == "off" and " · w to enable tracking" or ""))
    local since = Cockpit.since(thread, opts)
    if since.established then
      add(string.format("Since check: %d completed · %d files · test %s", since.completed_turns, #since.files,
        since.test_changed and "updated" or "unchanged"))
    else add("Since check: no checkpoint · u marks current history checked") end
    local attention = Cockpit.attention(thread, runtime, opts)
    add(""); add("## Attention" .. (attention.snoozed and " · snoozed" or ""))
    for _, item in ipairs(attention.items) do add("- " .. text(item.label)) end
    if #attention.items == 0 then add("No pending attention items.") end
    local activity = Activity.summarize(supplied_runtime)
    add(""); add("## Activity")
    add(activity.label)
    local data = activity.data or {}
    add("Last received: " .. (data.received_at and os.date("!%Y-%m-%d %H:%M:%S UTC", data.received_at) or "unknown"))
    for _, tool in ipairs(data.tools or {}) do add("- Tool [" .. text(tool.state) .. "]: " .. text(tool.title)) end
    local function tasks(label, list, counts)
      if not counts or counts.total == 0 then return end
      add(string.format("%s: %d active · %d finished · %d failed · %d unknown", label,
        counts.active, counts.completed, counts.failed, counts.unknown))
      for _, item in ipairs(list or {}) do
        add("- [" .. text(item.state) .. "] " .. text(item.title))
        if item.detail and item.detail ~= "" then add("  " .. text(item.detail)) end
        if item.last_tool and item.last_tool ~= "" then add("  Last tool: " .. text(item.last_tool)) end
      end
      if counts.total > #(list or {}) then add("… " .. (counts.total - #(list or {})) .. " more") end
    end
    tasks("Subagents", data.children, data.child_counts)
    tasks("Background tasks", data.tasks, data.task_counts)
    local progress = data.plan or {}
    if (progress.total or 0) > 0 then add(string.format("Plan: %d/%d items completed", progress.completed, progress.total)) end
    if runtime.acp_goal then add(""); add("Goal: " .. text(runtime.acp_goal)) end
    local plan = runtime.acp_plan or {}
    for _, entry in ipairs(plan.entries or plan) do
      add("- [" .. text(entry.status or "pending") .. "] " .. text(entry.content or entry.text or entry.title))
    end
    add(""); add("Tests: " .. Cockpit.test_status(thread, opts))
    add("Queued prompts: " .. #(runtime.acp_prompt_queue or {}))
    add("Subagents: " .. vim.tbl_count(runtime.acp_subagents or {}) .. " · async tasks: " .. vim.tbl_count(runtime.acp_async_tasks or {}))
  end
  return lines
end

return M
