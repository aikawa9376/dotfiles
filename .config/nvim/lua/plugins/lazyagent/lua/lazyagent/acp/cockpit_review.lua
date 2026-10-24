local M = {}
M.states = { off = true, not_started = true, reviewing = true, changes_requested = true, done = true }

function M.enabled(thread)
  local saved = thread and thread.metadata and thread.metadata.cockpit_review
  return type(saved) == "table" and saved.enabled == true and saved.thread_id == thread.thread_id
end

local function hash(value) return vim.fn.sha256(vim.json.encode(value)) end
local function blob_token(blob, fallback)
  return type(blob) == "table" and type(blob.hash) == "string" and ("blob:" .. blob.hash) or fallback
end

-- Retain identifiers/digests and counts, never duplicate transcript or blob bodies.
function M.snapshot(thread, opts)
  local code_only = opts and opts.code_only
  local files, turns = {}, {}
  for _, turn in ipairs(thread.change_journal and thread.change_journal.turns or {}) do
    local id = tostring(turn.turn_id or "unknown")
    local decisions, notes = {}, {}
    for index, change in ipairs(turn.changes or {}) do
      local path = change.path or change.new_path or change.old_path
      local operation = change.operation
      if path then
        local unknown = "unknown:" .. id .. ":" .. index
        if change.decision == "rejected" then
          files[path] = operation == "added" and "deleted" or blob_token(change.before_blob, unknown .. ":before")
          if operation == "moved" and change.previous_path then
            files[path] = "deleted"
            files[change.previous_path] = blob_token(change.before_blob, unknown .. ":before")
          end
        else
          files[path] = operation == "deleted" and "deleted" or blob_token(change.review_blob or change.after_blob, unknown)
          if operation == "moved" and change.previous_path then files[change.previous_path] = "deleted" end
        end
      end
      if not code_only then
        local hunks = {}
        for _, hunk in ipairs(change.hunks or {}) do hunks[#hunks + 1] = { hunk.index, hunk.decision or "" } end
        decisions[#decisions + 1] = { path or "", change.decision or "", hunks }
      end
    end
    if turn.state == "active" then
      for path, revision in pairs(turn.file_revisions or {}) do
        files[path] = revision.after_seen and not revision.after_blob and "deleted"
          or blob_token(revision.after_blob, "unknown:" .. id .. ":" .. tostring(revision.event_count))
      end
    end
    if not code_only then
      for _, annotation in ipairs(turn.annotations or {}) do
        notes[#notes + 1] = { annotation.id or "", annotation.summary or "", annotation.rationale or "" }
      end
      turns[#turns + 1] = {
        id, turn.state or "", #(turn.tools or {}), #(turn.file_events or {}), #(turn.buffer_events or {}),
        hash(decisions), hash(notes),
      }
    end
  end
  local paths, file_list = vim.tbl_keys(files), {}
  table.sort(paths)
  for _, path in ipairs(paths) do file_list[#file_list + 1] = { path, files[path] } end
  local test = thread.metadata and thread.metadata.test_result or {}
  local completion = thread.metadata and thread.metadata.cockpit_completion or {}
  local result = {
    schema_version = 1, thread_id = thread.thread_id, turns = turns, files = file_list,
    test = { test.run_id or test.finished_at or "", test.status or "", test.stale == true },
    completion_id = completion.id or "",
  }
  if opts and opts.include_code then
    result.code = { schema_version = 1, root = thread.cwd, refs = {} }
    for _, file in ipairs(file_list) do
      local digest = file[2]:match("^blob:([a-f0-9]+)$")
      if digest and #digest == 64 then
        result.code.refs[file[1]] = { algorithm = "sha256", hash = digest }
      end
    end
  end
  return result
end

function M.version(thread)
  local snapshot = M.snapshot(thread)
  local review = thread.metadata and thread.metadata.cockpit_review or {}
  return hash({ snapshot.turns, snapshot.files, snapshot.test, snapshot.completion_id,
    review.state or "", review.revision or "", review.changed_at or "", review.fingerprint or "",
    review.enabled == true, review.thread_id or "" })
end

function M.code_revision(thread) return hash(M.snapshot(thread, { code_only = true }).files) end

function M.since(thread)
  local seen = thread.metadata and thread.metadata.cockpit_observation
  local result = { established = false, new_turns = 0, completed_turns = 0, tool_events = 0, file_events = 0, review_updates = 0, files = {} }
  if type(seen) ~= "table" or seen.schema_version ~= 1 or seen.thread_id ~= thread.thread_id then return result end
  local current = M.snapshot(thread)
  local old_turns, current_ids, old_files, current_files = {}, {}, {}, {}
  for _, turn in ipairs(seen.turns or {}) do old_turns[turn[1]] = turn end
  for _, turn in ipairs(current.turns) do
    local old = old_turns[turn[1]]
    current_ids[turn[1]] = true
    if not old then result.new_turns = result.new_turns + 1 end
    if turn[2] == "completed" and (not old or old[2] ~= "completed") then result.completed_turns = result.completed_turns + 1 end
    result.tool_events = result.tool_events + math.max(0, turn[3] - (old and old[3] or 0))
    result.file_events = result.file_events + math.max(0, turn[4] + turn[5] - (old and (old[4] + old[5]) or 0))
    if old and (old[6] ~= turn[6] or old[7] ~= turn[7]) then result.review_updates = result.review_updates + 1 end
  end
  for id in pairs(old_turns) do if not current_ids[id] then result.history_gap = true end end
  for _, file in ipairs(seen.files or {}) do old_files[file[1]] = file[2] end
  for _, file in ipairs(current.files) do current_files[file[1]] = file[2] end
  for path, token in pairs(current_files) do
    if old_files[path] ~= token then result.files[#result.files + 1] = path end
  end
  -- A removed journal entry is an observation gap, not evidence of filesystem deletion.
  for path in pairs(old_files) do if current_files[path] == nil then result.history_gap = true end end
  table.sort(result.files)
  result.established = true
  result.test_changed = not vim.deep_equal(seen.test, current.test)
  result.completion_changed = seen.completion_id ~= current.completion_id
  result.revision = hash({ current.turns, current.files, current.test, current.completion_id })
  result.changed = result.new_turns > 0 or result.completed_turns > 0 or #result.files > 0
    or result.tool_events > 0 or result.file_events > 0 or result.review_updates > 0
    or result.test_changed or result.completion_changed or result.history_gap == true
  return result
end

function M.summary(thread, opts)
  opts = opts or {}
  local saved = thread.metadata and thread.metadata.cockpit_review or {}
  local revision = M.code_revision(thread)
  local enabled = M.enabled(thread)
  local state = enabled and (M.states[saved.state] and saved.state or "not_started") or "off"
  local changed = saved.revision ~= revision
  if state == "done" then
    if changed or opts.busy then state = "needs_review"
    elseif opts.fingerprint_pending then state = "checking"
    elseif type(saved.fingerprint) ~= "string" or type(opts.fingerprint) ~= "string" then state = "unverified"
    elseif saved.fingerprint ~= opts.fingerprint then state = "needs_review" end
  elseif state == "changes_requested" and changed and not opts.busy then
    state = "ready_for_review"
  end
  local latest
  for _, turn in ipairs(thread.change_journal and thread.change_journal.turns or {}) do
    if #(turn.changes or {}) > 0 then latest = turn end
  end
  local counts = { approved = 0, rejected = 0, pending = 0, notes = 0, hunks_decided = 0, hunks_total = 0 }
  for _, change in ipairs(latest and latest.changes or {}) do
    local key = change.decision == "kept" and "approved" or change.decision == "rejected" and "rejected" or "pending"
    counts[key] = counts[key] + 1
    for _, hunk in ipairs(change.hunks or {}) do
      counts.hunks_total = counts.hunks_total + 1
      if hunk.decision then counts.hunks_decided = counts.hunks_decided + 1 end
    end
  end
  for _, note in ipairs(latest and latest.annotations or {}) do
    if note.author and note.author.type == "user" then counts.notes = counts.notes + 1 end
  end
  return { enabled = enabled, state = state, saved_state = saved.state, revision = revision, counts = counts,
    turn_id = latest and latest.turn_id, changed_at = saved.changed_at }
end

return M
