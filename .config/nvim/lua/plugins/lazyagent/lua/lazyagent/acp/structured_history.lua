local M = {}

local SCHEMA_VERSION = 1

local function copy(value)
  return vim.deepcopy(type(value) == "table" and value or {})
end

local function json_encode(value)
  return vim.json and vim.json.encode(value) or vim.fn.json_encode(value)
end

local function json_decode(value)
  return vim.json and vim.json.decode(value) or vim.fn.json_decode(value)
end

local function ensure_parent(path)
  local dir = vim.fn.fnamemodify(path, ":h")
  if vim.fn.isdirectory(dir) == 0 and vim.fn.mkdir(dir, "p", 448) == 0 then
    return nil, "failed to create structured history directory: " .. dir
  end
  return true
end

local function portable_item(item, resolve_body)
  item = copy(item)
  local body = type(resolve_body) == "function" and resolve_body(item) or item.body
  item.body = tostring(body or "")
  item.body_ref = nil
  item.body_chunks = nil
  item.stream_key = nil
  item._summary_source = nil
  return item
end

function M.path(base_dir, thread_id)
  return string.format("%s/acp/history/%s.jsonl", tostring(base_dir), tostring(thread_id))
end

function M.turn_record(turn, conversation, resolve_body)
  turn = copy(turn)
  local first = math.max(1, (tonumber(turn.conversation_start_seq) or 0) + 1)
  local last = math.min(#(conversation or {}), tonumber(turn.conversation_end_seq) or #(conversation or {}))
  local items = {}
  for index = first, last do
    local item = conversation[index]
    if type(item) == "table" then
      items[#items + 1] = portable_item(item, resolve_body)
    end
  end
  return {
    schema_version = SCHEMA_VERSION,
    turn_id = turn.turn_id,
    state = turn.state,
    started_at = turn.started_at,
    finished_at = turn.finished_at,
    user_input = turn.user_input,
    conversation_start_seq = turn.conversation_start_seq,
    conversation_end_seq = turn.conversation_end_seq,
    transcript_end_line = turn.transcript_end_line,
    conversation = items,
    tools = copy(turn.tools),
    changes = copy(turn.changes),
  }
end

function M.append(path, record)
  local ok, dir_err = ensure_parent(path)
  if not ok then return nil, dir_err end
  local encoded_ok, encoded = pcall(json_encode, record)
  if not encoded_ok then return nil, encoded end
  local write_ok, write_err = pcall(vim.fn.writefile, { encoded }, path, "a")
  if not write_ok or write_err ~= 0 then
    return nil, write_ok and "failed to append structured history" or write_err
  end
  if vim.uv and vim.uv.fs_chmod then pcall(vim.uv.fs_chmod, path, 384) end
  return true
end

function M.read(path)
  if not path or path == "" or vim.fn.filereadable(path) ~= 1 then return {} end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then return nil, lines end
  local records = {}
  for line_number, line in ipairs(lines) do
    if line ~= "" then
      local decoded_ok, decoded = pcall(json_decode, line)
      if not decoded_ok or type(decoded) ~= "table" then
        return nil, string.format("invalid structured history at line %d", line_number)
      end
      records[#records + 1] = decoded
    end
  end
  return records
end

function M.slice(records, turn_id)
  local sliced = {}
  local found = false
  for _, record in ipairs(records or {}) do
    sliced[#sliced + 1] = copy(record)
    if record.turn_id == turn_id then
      found = true
      break
    end
  end
  if not found then return nil, "structured history turn not found: " .. tostring(turn_id) end
  return sliced
end

function M.write(path, records)
  local ok, dir_err = ensure_parent(path)
  if not ok then return nil, dir_err end
  local lines = {}
  for _, record in ipairs(records or {}) do
    local encoded_ok, encoded = pcall(json_encode, record)
    if not encoded_ok then return nil, encoded end
    lines[#lines + 1] = encoded
  end
  local temporary = path .. ".tmp." .. tostring(vim.fn.getpid())
  local write_ok, write_err = pcall(vim.fn.writefile, lines, temporary)
  if not write_ok or write_err ~= 0 then
    return nil, write_ok and "failed to write structured history" or write_err
  end
  if vim.uv and vim.uv.fs_chmod then pcall(vim.uv.fs_chmod, temporary, 384) end
  local renamed, rename_err = (vim.uv or vim.loop).fs_rename(temporary, path)
  if not renamed then
    pcall(vim.fn.delete, temporary)
    return nil, rename_err
  end
  return true
end

function M.conversation(records)
  local items = {}
  for _, record in ipairs(records or {}) do
    for _, item in ipairs(record.conversation or {}) do
      local portable = copy(item)
      portable.seq = #items + 1
      items[#items + 1] = portable
    end
  end
  return items
end

local function is_user_header(line)
  line = tostring(line or "")
  return line:match("^─ .- User%s+─") ~= nil or line:match("^#+%s+User%s*$") ~= nil
end

function M.transcript_slice(lines, turn_number, transcript_end_line)
  lines = copy(lines)
  local explicit_end = tonumber(transcript_end_line)
  if explicit_end and explicit_end > 0 then
    return vim.list_slice(lines, 1, math.min(#lines, explicit_end))
  end

  turn_number = math.max(1, tonumber(turn_number) or 1)
  local user_headers = {}
  for line_number, line in ipairs(lines) do
    if is_user_header(line) then user_headers[#user_headers + 1] = line_number end
  end
  local next_header = user_headers[turn_number + 1]
  if not next_header then return lines end
  local last = math.max(1, next_header - 1)
  while last > 1 and vim.trim(tostring(lines[last] or "")) == "" do last = last - 1 end
  return vim.list_slice(lines, 1, last)
end

M.SCHEMA_VERSION = SCHEMA_VERSION

return M
