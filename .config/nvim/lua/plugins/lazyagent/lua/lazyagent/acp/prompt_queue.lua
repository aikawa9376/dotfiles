local M = {}

local function queue(session)
  session.prompt_queue = session.prompt_queue or {}
  return session.prompt_queue
end

local function index_of(session, id)
  for index, item in ipairs(queue(session)) do
    if type(item) == "table" and item.id == id then
      return index, item
    end
  end
  return nil
end

function M.push(session, text)
  session.prompt_queue_seq = (tonumber(session.prompt_queue_seq) or 0) + 1
  local item = {
    id = "prompt-" .. tostring(session.prompt_queue_seq),
    text = tostring(text or ""),
    created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  }
  queue(session)[#queue(session) + 1] = item
  return vim.deepcopy(item)
end

function M.pop(session)
  local item = table.remove(queue(session), 1)
  if type(item) == "string" then
    return { id = "legacy", text = item }
  end
  return item
end

function M.list(session)
  return vim.deepcopy(queue(session))
end

function M.edit(session, id, text)
  local _, item = index_of(session, id)
  if not item then return nil, "queued prompt not found: " .. tostring(id) end
  text = tostring(text or ""):gsub("\n+$", "")
  if text == "" then return nil, "queued prompt must not be empty" end
  item.text = text
  item.edited_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  return vim.deepcopy(item)
end

function M.remove(session, id)
  local item = M.take(session, id)
  return item
end

function M.take(session, id)
  local index = index_of(session, id)
  if not index then return nil, "queued prompt not found: " .. tostring(id) end
  return vim.deepcopy(table.remove(queue(session), index)), index
end

function M.restore(session, item, index)
  if type(item) ~= "table" or not item.id or tostring(item.text or "") == "" then
    return nil, "invalid queued prompt"
  end
  local existing_index, existing = index_of(session, item.id)
  if existing then return vim.deepcopy(existing), existing_index end
  local items = queue(session)
  index = math.max(1, math.min(#items + 1, tonumber(index) or (#items + 1)))
  table.insert(items, index, vim.deepcopy(item))
  return vim.deepcopy(items[index]), index
end

function M.move(session, id, delta)
  local index = index_of(session, id)
  if not index then return nil, "queued prompt not found: " .. tostring(id) end
  local target = math.max(1, math.min(#queue(session), index + (tonumber(delta) or 0)))
  if target ~= index then
    local item = table.remove(queue(session), index)
    table.insert(queue(session), target, item)
  end
  return vim.deepcopy(queue(session)[target]), target
end

function M.promote(session, id)
  local index = index_of(session, id)
  if not index then return nil, "queued prompt not found: " .. tostring(id) end
  local item = table.remove(queue(session), index)
  table.insert(queue(session), 1, item)
  return vim.deepcopy(item)
end

return M
