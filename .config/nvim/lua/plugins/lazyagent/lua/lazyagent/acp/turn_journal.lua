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

function M.start(journal, thread_id, baseline)
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
    buffer_events = {},
  }
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

function M.finish(journal, turn_id, completion)
  journal = copy(journal)
  local turn = find_turn(journal, turn_id)
  if not turn then
    return nil, "turn not found: " .. tostring(turn_id)
  end
  completion = copy(completion)
  turn.state = completion.state or "completed"
  turn.finished_at = completion.finished_at
  turn.final_snapshot = completion.final_snapshot
  turn.changes = type(completion.changes) == "table" and completion.changes or {}
  turn.capture_error = completion.capture_error
  return journal, copy(turn)
end

function M.decide(journal, turn_id, indices, decision, decided_at)
  journal = copy(journal)
  local turn = find_turn(journal, turn_id)
  if not turn then
    return nil, "turn not found: " .. tostring(turn_id)
  end
  for _, index in ipairs(indices or {}) do
    local change = turn.changes and turn.changes[index] or nil
    if not change then
      return nil, "change not found: " .. tostring(index)
    end
    change.decision = decision
    change.decided_at = decided_at
  end
  return journal, copy(turn)
end

return M
