local M = {}

local valid_kinds = {
  explanation = true,
  review = true,
  comment = true,
  question = true,
  suggestion = true,
}

local function text(value)
  value = vim.trim(tostring(value or ""))
  return value ~= "" and value or nil
end

local function blob_hash(ref)
  if type(ref) == "table" then return text(ref.hash) end
  return nil
end

function M.normalize(annotation)
  annotation = type(annotation) == "table" and vim.deepcopy(annotation) or {}
  local target = type(annotation.target) == "table" and annotation.target or {}
  local normalized = {
    id = text(annotation.id),
    kind = valid_kinds[annotation.kind] and annotation.kind or "comment",
    summary = text(annotation.summary),
    rationale = text(annotation.rationale or annotation.body),
    path = text(annotation.path or target.path),
    target = {
      side = target.side == "before" and "before" or "after",
      start_line = tonumber(target.start_line or target.line),
      end_line = tonumber(target.end_line or target.start_line or target.line),
      blob_hash = text(target.blob_hash),
      context_hash = text(target.context_hash),
    },
    author = type(annotation.author) == "table" and vim.deepcopy(annotation.author) or nil,
    created_at = text(annotation.created_at),
  }
  if not normalized.summary and not normalized.rationale then return nil end
  normalized.id = normalized.id or vim.fn.sha256(vim.inspect(normalized)):sub(1, 16)
  return normalized
end

function M.normalize_all(annotations)
  local result = {}
  for _, annotation in ipairs(type(annotations) == "table" and annotations or {}) do
    local normalized = M.normalize(annotation)
    if normalized then result[#result + 1] = normalized end
  end
  return result
end

function M.for_change(turn, change, line)
  local result = {}
  local path = tostring(change and change.path or "")
  for _, annotation in ipairs(M.normalize_all(turn and turn.annotations)) do
    if annotation.path == path then
      local first = annotation.target.start_line
      local last = annotation.target.end_line or first
      if not line or not first or (line >= first and line <= last) then
        local expected = annotation.target.side == "before"
            and blob_hash(change.before_blob)
          or blob_hash(change.review_blob or change.after_blob)
        annotation.outdated = annotation.target.blob_hash ~= nil
          and expected ~= nil
          and annotation.target.blob_hash ~= expected
        result[#result + 1] = annotation
      end
    end
  end
  return result
end

function M.for_turn(turn)
  local result = {}
  for _, annotation in ipairs(M.normalize_all(turn and turn.annotations)) do
    if not annotation.path then result[#result + 1] = annotation end
  end
  return result
end

function M.latest_explanation(timeline, start_seq, resolve_body, author, created_at)
  for index = #(timeline or {}), (tonumber(start_seq) or 0) + 1, -1 do
    local item = timeline[index]
    if type(item) == "table" and (item.kind == "assistant" or item.heading == "Assistant") then
      local body = type(resolve_body) == "function" and resolve_body(item) or item.body
      if text(body) then
        return M.normalize({
          kind = "explanation",
          summary = item.summary,
          rationale = body,
          author = author,
          created_at = created_at,
        })
      end
    end
  end
  return nil
end

function M.markdown(annotations)
  local lines = {}
  local function append(value)
    vim.list_extend(lines, vim.split(tostring(value or ""), "\n", { plain = true }))
  end
  for index, annotation in ipairs(annotations or {}) do
    if index > 1 then vim.list_extend(lines, { "", "---", "" }) end
    lines[#lines + 1] = "## " .. annotation.kind:gsub("^%l", string.upper)
    if annotation.summary then
      lines[#lines + 1] = ""
      append(annotation.summary)
    end
    if annotation.rationale and annotation.rationale ~= annotation.summary then
      lines[#lines + 1] = ""
      append(annotation.rationale)
    end
    if annotation.outdated then
      vim.list_extend(lines, { "", "> This note may be outdated because the target blob changed." })
    end
    local author = annotation.author and (annotation.author.name or annotation.author.provider) or nil
    if author then vim.list_extend(lines, { "", "_" .. tostring(author) .. "_" }) end
  end
  return lines
end

return M
