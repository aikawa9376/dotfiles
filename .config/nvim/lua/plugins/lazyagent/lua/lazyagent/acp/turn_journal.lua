local M = {}

local function copy(value)
  return vim.deepcopy(type(value) == "table" and value or {})
end

local function find_turn(journal, turn_id)
  for _, turn in ipairs(journal.turns or {}) do
    if turn.turn_id == turn_id then
      return turn
    end
  end
  return nil
end

local function compact_snapshot(snapshot)
  if type(snapshot) ~= "table" then
    return snapshot
  end
  return {
    root = snapshot.root,
    vcs = copy(snapshot.vcs),
    captured_at = snapshot.captured_at,
    schema_version = snapshot.schema_version,
    truncated = snapshot.truncated == true,
    file_count = tonumber(snapshot.file_count) or #(snapshot.files or {}),
    dirty_count = tonumber(snapshot.dirty_count) or #(snapshot.dirty or {}),
    untracked_count = tonumber(snapshot.untracked_count) or #(snapshot.untracked or {}),
    git_error = snapshot.git_error,
  }
end

local function event_path(event)
  return tostring(event.relative_path or ""):gsub("^/+", "")
end

local function copy_blob(blob)
  return type(blob) == "table" and vim.deepcopy(blob) or nil
end

local function update_file_revision(turn, event)
  local path = event_path(event)
  if path == "" then return end
  turn.file_revisions = type(turn.file_revisions) == "table" and turn.file_revisions or {}
  local revision = turn.file_revisions[path]
  if not revision then
    revision = { before_blob = copy_blob(event.before_blob), event_count = 0 }
    turn.file_revisions[path] = revision
  end
  revision.event_count = (tonumber(revision.event_count) or 0) + 1
  if event.after_blob then
    revision.after_blob = copy_blob(event.after_blob)
    revision.after_seen = true
  elseif event.operation == "deleted" then
    revision.after_blob = nil
    revision.after_seen = true
  end
end

local function legacy_file_revisions(turn)
  local revisions = {}
  for _, event in ipairs(turn.file_events or {}) do
    local path = event_path(event)
    if path ~= "" then
      local revision = revisions[path]
      if not revision then
        revision = { before_blob = copy_blob(event.before_blob), event_count = 0 }
        revisions[path] = revision
      end
      revision.event_count = revision.event_count + 1
      if event.after_blob then
        revision.after_blob = copy_blob(event.after_blob)
        revision.after_seen = true
      elseif event.operation == "deleted" then
        revision.after_blob = nil
        revision.after_seen = true
      end
    end
  end
  return revisions
end

function M.start(journal, thread_id, baseline, metadata)
  journal = copy(journal)
  journal.turns = type(journal.turns) == "table" and journal.turns or {}
  local sequence = math.max(1, tonumber(journal.next_turn_sequence) or (#journal.turns + 1))
  local turn = {
    turn_id = string.format("%s:%d", thread_id, sequence),
    state = "active",
    started_at = baseline.captured_at,
    baseline = copy(baseline),
    tools = {},
    file_events = {},
    file_revisions = {},
    buffer_events = {},
    annotations = {},
  }
  for key, value in pairs(type(metadata) == "table" and metadata or {}) do
    turn[key] = vim.deepcopy(value)
  end
  journal.turns[#journal.turns + 1] = turn
  journal.next_turn_sequence = sequence + 1
  return journal, copy(turn)
end

function M.record(journal, turn_id, kind, event)
  journal = copy(journal)
  local turn = find_turn(journal, turn_id)
  if not turn then
    return nil, "turn not found: " .. tostring(turn_id)
  end
  event = copy(event)
  if kind == "tool" then
    turn.tools = type(turn.tools) == "table" and turn.tools or {}
    local existing = nil
    for _, tool in ipairs(turn.tools) do
      if tool.tool_call_id == event.tool_call_id then
        existing = tool
        break
      end
    end
    if existing then
      for key, value in pairs(event) do
        existing[key] = value
      end
    else
      turn.tools[#turn.tools + 1] = event
    end
  elseif kind == "file" then
    turn.file_events = type(turn.file_events) == "table" and turn.file_events or {}
    turn.file_events[#turn.file_events + 1] = event
    update_file_revision(turn, event)
  elseif kind == "buffer" then
    turn.buffer_events = type(turn.buffer_events) == "table" and turn.buffer_events or {}
    turn.buffer_events[#turn.buffer_events + 1] = event
  else
    return nil, "unsupported turn event: " .. tostring(kind)
  end
  return journal, copy(turn)
end

function M.get(journal, turn_id)
  local turn = find_turn(type(journal) == "table" and journal or {}, turn_id)
  return turn and copy(turn) or nil
end

function M.add_annotation(journal, turn_id, annotation)
  journal = copy(journal)
  local turn = find_turn(journal, turn_id)
  if not turn then return nil, "turn not found: " .. tostring(turn_id) end
  local normalized = require("lazyagent.acp.review_annotations").normalize(annotation)
  if not normalized then return nil, "review note is empty" end
  turn.annotations = type(turn.annotations) == "table" and turn.annotations or {}
  turn.annotations[#turn.annotations + 1] = normalized
  return journal, copy(turn), copy(normalized)
end

function M.remove_annotations(journal, turn_id, ids)
  journal = copy(journal)
  local turn = find_turn(journal, turn_id)
  if not turn then return nil, "turn not found: " .. tostring(turn_id) end
  local remove = {}
  for _, id in ipairs(ids or {}) do remove[tostring(id)] = true end
  local kept = {}
  for _, annotation in ipairs(turn.annotations or {}) do
    if not remove[tostring(annotation.id)] then kept[#kept + 1] = annotation end
  end
  turn.annotations = kept
  return journal, copy(turn)
end

function M.recover_file_event_changes(journal, resolve_before)
  journal = copy(journal)
  local recovered = 0
  for _, turn in ipairs(journal.turns or {}) do
    turn.changes = type(turn.changes) == "table" and turn.changes or {}
    local known = {}
    for _, change in ipairs(turn.changes) do known[change.path] = true end
    local revisions = turn.file_revisions ~= nil and copy(turn.file_revisions) or legacy_file_revisions(turn)
    for path, revision in pairs(revisions) do
      if not known[path] and revision.after_seen then
        local before_blob = revision.before_blob
        if not before_blob and type(resolve_before) == "function" then
          before_blob = resolve_before(turn, path)
        end
        local after_blob = revision.after_blob
        local changed = before_blob == nil or after_blob == nil
          or tostring(before_blob.hash or "") ~= tostring(after_blob.hash or "")
        if changed and (before_blob or after_blob) then
          turn.changes[#turn.changes + 1] = {
            path = path,
            operation = before_blob and (after_blob and "modified" or "deleted") or "added",
            before_size = before_blob and before_blob.size or nil,
            after_size = after_blob and after_blob.size or nil,
            before_blob = before_blob,
            after_blob = after_blob,
            binary = (before_blob and before_blob.binary == true) or (after_blob and after_blob.binary == true) or false,
          }
          recovered = recovered + 1
        end
      end
    end
    table.sort(turn.changes, function(left, right) return tostring(left.path) < tostring(right.path) end)
  end
  return journal, recovered
end

function M.preview_changes(journal, turn_id, resolve_before)
  journal = copy(journal)
  local turn = find_turn(journal, turn_id)
  if not turn then return nil, "turn not found: " .. tostring(turn_id) end
  turn.changes = {}
  local recovered
  journal, recovered = M.recover_file_event_changes(journal, resolve_before)
  return journal, copy(find_turn(journal, turn_id)), recovered
end

function M.finish(journal, turn_id, completion)
  journal = copy(journal)
  local turn = find_turn(journal, turn_id)
  if not turn then
    return nil, "turn not found: " .. tostring(turn_id)
  end
  completion = copy(completion)
  turn.state = completion.state or "completed"
  turn.finished_at = completion.finished_at
  turn.baseline = compact_snapshot(completion.baseline or turn.baseline)
  turn.final_snapshot = compact_snapshot(completion.final_snapshot)
  turn.changes = type(completion.changes) == "table" and completion.changes or {}
  turn.annotations = require("lazyagent.acp.review_annotations").normalize_all(
    completion.annotations or turn.annotations
  )
  turn.capture_error = completion.capture_error
  return journal, copy(turn)
end

function M.compact(journal)
  journal = copy(journal)
  for _, turn in ipairs(journal.turns or {}) do
    if turn.state ~= "active" then
      turn.baseline = compact_snapshot(turn.baseline)
      turn.final_snapshot = compact_snapshot(turn.final_snapshot)
    end
  end
  return journal
end

function M.decide(journal, turn_id, indices, decision, decided_at, applications)
  journal = copy(journal)
  local turn = find_turn(journal, turn_id)
  if not turn then
    return nil, "turn not found: " .. tostring(turn_id)
  end
  for position, index in ipairs(indices or {}) do
    local change = turn.changes and turn.changes[index] or nil
    if not change then
      return nil, "change not found: " .. tostring(index)
    end
    change.decision = decision
    change.decided_at = decided_at
    local application = applications and applications[position] or nil
    if application and application.mode then
      change.apply_mode = application.mode
    end
  end
  return journal, copy(turn)
end

function M.decide_hunk(journal, turn_id, change_index, canonical_hunks, hunk_index, decision, review_blob, decided_at)
  journal = copy(journal)
  local turn = find_turn(journal, turn_id)
  local change = turn and turn.changes and turn.changes[change_index] or nil
  if not change then
    return nil, "change not found: " .. tostring(change_index)
  end
  local previous = {}
  for _, hunk in ipairs(change.hunks or {}) do
    previous[hunk.index] = hunk
  end
  change.hunks = copy(canonical_hunks)
  for _, hunk in ipairs(change.hunks) do
    local saved = previous[hunk.index]
    if saved then
      hunk.decision = saved.decision
      hunk.decided_at = saved.decided_at
    end
  end
  local hunk = change.hunks[hunk_index]
  if not hunk then
    return nil, "hunk not found: " .. tostring(hunk_index)
  end
  if hunk.decision then
    return nil, "hunk already decided: " .. tostring(hunk_index)
  end
  hunk.decision = decision
  hunk.decided_at = decided_at
  if review_blob then
    change.review_blob = copy(review_blob)
  end
  return journal, copy(turn)
end

return M
