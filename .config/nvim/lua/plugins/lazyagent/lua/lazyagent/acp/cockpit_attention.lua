local M = {}

function M.summarize(thread, runtime, opts)
  opts = opts or {}
  runtime = runtime or {}
  local metadata = thread.metadata or {}
  local items = {}
  local function add(kind, label, key, priority)
    items[#items + 1] = { kind = kind, label = label, key = tostring(key or kind), priority = priority }
  end
  if thread.status == "archived" and next(runtime) == nil then return { items = {}, priority = 99, signature = "" } end
  local requests = runtime.acp_ui_requests or {}
  local queued = {}
  if requests.active then queued[#queued + 1] = requests.active end
  vim.list_extend(queued, requests.pending or {})
  local permission = false
  for _, request in ipairs(queued) do
    local kind = request.kind or "input"
    permission = permission or kind == "permission"
    add(kind, (kind == "permission" and "Approve: " or "Input: ") .. tostring(request.label or kind), request.id, 1)
  end
  if not permission and (runtime.acp_pending_permission
    or (tonumber((runtime.acp_client_debug or {}).pending_permissions) or 0) > 0)
  then
    local pending = runtime.acp_pending_permission or {}
    add("permission", "Approve: " .. tostring(pending.title or "Permission required"), pending.request_id, 1)
  end
  local failure = runtime.acp_active_session_failure
  if runtime.acp_failed == true or thread.status == "failed" or opts.status == "disconnected" or failure then
    add("error", failure and failure.title or "Session needs recovery", failure and (failure.id .. ":" .. failure.revision)
      or (opts.status or thread.status), 2)
  elseif opts.status == "waiting" and #items == 0 then
    add("input", "Waiting for input", "waiting", 1)
  end
  local result = metadata.test_result
  if result and result.status ~= "running" then
    if opts.test_status == "stale" then
      add("test", "Tests need rerun", tostring(result.run_id or result.finished_at) .. ":stale", 3)
    elseif result.status == "failed" then
      add("test", "Test failed" .. (opts.test_status == "unknown" and " (unverified)" or ""),
        result.run_id or result.finished_at or "failed", 3)
    end
  end
  local completion = metadata.cockpit_completion
  if type(completion) == "table" and completion.id and metadata.cockpit_ack_completion ~= completion.id then
    add("completion", "Completed · not acknowledged", completion.id, 4)
  end
  local review = opts.review or {}
  if review.state == "needs_review" or review.state == "ready_for_review" then
    add("review", "Changes need review", tostring(review.revision) .. ":" .. review.state, 3)
  elseif review.state == "unverified" then
    add("review", "Review freshness unknown", "unverified:" .. tostring(review.revision), 3)
  end
  local since = opts.since or {}
  if since.established and since.changed then
    add("updates", since.history_gap and "Recorded history changed; recheck"
      or (string.format("Since check: %d completed, %d files", since.completed_turns, #(since.files or {}))
        .. (since.test_changed and ", test updated" or "")), since.revision, 4)
  end
  local keys, priority = {}, 99
  for _, item in ipairs(items) do
    keys[#keys + 1] = item.kind .. ":" .. item.key
    priority = math.min(priority, item.priority)
  end
  local signature = table.concat(keys, "|")
  local snooze = opts.snoozed and opts.snoozed[thread.thread_id]
  return {
    items = items, signature = signature, priority = priority,
    snoozed = snooze ~= nil and snooze.signature == signature and snooze.until_at > (opts.now or os.time()),
  }
end

return M
