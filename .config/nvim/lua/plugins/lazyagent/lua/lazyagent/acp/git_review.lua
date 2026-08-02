local M = {}

local allowed_labels = { must = true, should = true, imo = true, question = true, nit = true, praise = true }

local function default_run(argv)
  local result = vim.system(argv, { text = false }):wait()
  return { code = result.code, stdout = result.stdout or "", stderr = result.stderr or "" }
end

local function trim(value)
  return tostring(value or ""):gsub("%s+$", "")
end

local function split_zero(value)
  local out = {}
  for item in tostring(value or ""):gmatch("([^%z]+)") do out[#out + 1] = item end
  return out
end

local function resolve(run, root, rev)
  local result = run({ "git", "-C", root, "rev-parse", "--verify", rev .. "^{commit}" })
  if result.code ~= 0 then return nil, trim(result.stderr) ~= "" and trim(result.stderr) or "invalid revision: " .. rev end
  return trim(result.stdout)
end

local function content_id(root, base, head, changes)
  local parts = { root or "", base or "", head or "" }
  for _, change in ipairs(changes or {}) do
    local before = type(change.before_blob) == "table" and change.before_blob.hash or ""
    local after = type(change.after_blob) == "table" and change.after_blob.hash or ""
    parts[#parts + 1] = table.concat({ change.operation or "", change.previous_path or "", change.path or "", before, after }, "\0")
  end
  return vim.fn.sha256(table.concat(parts, "\0")):sub(1, 20)
end

local function review_id(changeset_id, created_at, nonce)
  return vim.fn.sha256(table.concat({ changeset_id, created_at, tostring(nonce) }, "\0")):sub(1, 20)
end

local function blob_at(run, blobs, root, commit, path)
  if not commit or not path then return nil end
  local result = run({ "git", "-C", root, "show", commit .. ":" .. path })
  if result.code ~= 0 then return nil end
  local ref, err = blobs:put(result.stdout, { max_bytes = false })
  if ref then ref.binary = result.stdout:find("\0", 1, true) ~= nil end
  return ref, err
end

function M.create(range, opts)
  opts = opts or {}
  if type(opts.blob_store) ~= "table" or type(opts.blob_store.put) ~= "function" then
    return nil, "Git review requires a blob store"
  end
  local run = opts.run or default_run
  local cwd = tostring(opts.cwd or vim.fn.getcwd())
  local root_result = run({ "git", "-C", cwd, "rev-parse", "--show-toplevel" })
  if root_result.code ~= 0 then return nil, "not inside a Git repository" end
  local root = vim.fn.fnamemodify(trim(root_result.stdout), ":p"):gsub("/$", "")
  range = vim.trim(tostring(range or ""))
  if range == "" then range = "HEAD~1..HEAD" end

  local left, right, mode
  if range:find("...", 1, true) then
    left, right = range:match("^(.-)%.%.%.(.+)$")
    mode = "merge-base"
  elseif range:find("..", 1, true) then
    left, right = range:match("^(.-)%.%.(.+)$")
    mode = "direct"
  else
    left, right, mode = range .. "^", range, "commit"
  end
  if not left or left == "" or not right or right == "" then return nil, "invalid Git review range: " .. range end
  local left_hash, left_err = resolve(run, root, left)
  if not left_hash then return nil, left_err end
  local head, head_err = resolve(run, root, right)
  if not head then return nil, head_err end
  local base = left_hash
  if mode == "merge-base" then
    local merged = run({ "git", "-C", root, "merge-base", left_hash, head })
    if merged.code ~= 0 then return nil, trim(merged.stderr) ~= "" and trim(merged.stderr) or "merge-base failed" end
    base = trim(merged.stdout)
  end

  local names = run({ "git", "-C", root, "diff", "--name-status", "-z", "--find-renames", base, head })
  if names.code ~= 0 then return nil, trim(names.stderr) ~= "" and trim(names.stderr) or "git diff failed" end
  local tokens, changes, index = split_zero(names.stdout), {}, 1
  while index <= #tokens do
    local status = tokens[index]
    local code = status:sub(1, 1)
    local old_path, path
    if code == "R" or code == "C" then
      old_path, path = tokens[index + 1], tokens[index + 2]
      index = index + 3
    else
      path = tokens[index + 1]
      old_path = path
      index = index + 2
    end
    local operation = code == "A" and "added" or code == "D" and "deleted" or code == "R" and "moved" or "modified"
    local before = operation ~= "added" and blob_at(run, opts.blob_store, root, base, old_path) or nil
    local after = operation ~= "deleted" and blob_at(run, opts.blob_store, root, head, path) or nil
    changes[#changes + 1] = {
      operation = operation,
      path = path,
      previous_path = operation == "moved" and old_path or nil,
      before_blob = before,
      after_blob = after,
      binary = (before and before.binary == true) or (after and after.binary == true) or false,
    }
  end

  local created_at = (opts.clock or function() return os.date("!%Y-%m-%dT%H:%M:%SZ") end)()
  local changeset_id = content_id(root, base, head, changes)
  return {
    schema_version = 2,
    review_id = review_id(changeset_id, created_at, opts.nonce or (vim.uv or vim.loop).hrtime()),
    changeset_id = changeset_id,
    lineage_id = changeset_id,
    root = root,
    range = range,
    mode = mode,
    base = base,
    head = head,
    created_at = created_at,
    status = "pending",
    changes = changes,
    annotations = {},
    source = { kind = "range", frontend = "change_review", mutable = false, range = range },
  }
end

---Create a review from an already captured immutable comparison.
---@param snapshot table
---@param opts? table
function M.from_snapshot(snapshot, opts)
  opts = opts or {}
  if type(snapshot) ~= "table" or type(snapshot.root) ~= "string" or type(snapshot.changes) ~= "table" then
    return nil, "invalid review snapshot"
  end
  local changes = vim.deepcopy(snapshot.changes)
  local created_at = (opts.clock or function() return os.date("!%Y-%m-%dT%H:%M:%SZ") end)()
  local changeset_id = content_id(snapshot.root, snapshot.base, snapshot.head, changes)
  return {
    schema_version = 2,
    review_id = review_id(changeset_id, created_at, opts.nonce or (vim.uv or vim.loop).hrtime()),
    changeset_id = changeset_id,
    lineage_id = snapshot.lineage_id or changeset_id,
    root = snapshot.root,
    range = snapshot.range or snapshot.title or "Diffview",
    mode = snapshot.mode or "snapshot",
    base = snapshot.base,
    head = snapshot.head,
    created_at = created_at,
    status = "pending",
    changes = changes,
    annotations = {},
    source = vim.deepcopy(snapshot.source or { kind = "snapshot", frontend = "change_review", mutable = false }),
    parent_review_id = snapshot.parent_review_id,
  }
end

function M.prompt(review)
  local lines = {}
  local instructions = vim.trim(tostring(review and review.instructions or ""))
  if instructions ~= "" then
    vim.list_extend(lines, {
      "Additional review instructions from the user:",
      instructions,
      "",
    })
  end
  vim.list_extend(lines, {
    "Perform a read-only code review of the immutable Git comparison below.",
    "Inspect the exact diff and surrounding code yourself using Git and read-only tools.",
    "Do not edit, create, delete, format, or otherwise modify files.",
    "Report only concrete findings that are useful to show inline in the diff.",
    "A finding may target either side, a file as a whole, or the review as a whole.",
    "A finding may target an unchanged after-side line in a changed file when that surrounding code is directly relevant.",
    "Prefer a before or after line target for every textual finding, including findings that concern several nearby lines.",
    "Use side file only when no meaningful line can be identified, such as a binary-file issue or a genuinely whole-file concern.",
    "Do not use side file merely because exact line mapping takes extra effort; inspect the requested revision and provide its line number.",
    "Do not report unrelated pre-existing issues.",
    "Labels: must, should, imo, question, nit, praise.",
    "Your entire final response must be exactly one fenced block in this form:",
    "```lazyagent-review",
    '{"review_id":"' .. tostring(review.review_id) .. '","findings":[{"label":"must","path":"file.lua","side":"after","line":12,"end_line":12,"summary":"Short title","rationale":"Why this matters"}]}',
    "```",
    "The example finding only demonstrates the schema; do not copy it.",
    "Use side before or after for line findings, side file with no line for file findings, and omit path with side overall for overall findings.",
    "Return an empty findings array when there are no findings.",
    "",
    "Repository root: " .. tostring(review.root),
    "Git range: " .. tostring(review.range),
    "Base: " .. tostring(review.base),
    "Head: " .. tostring(review.head),
  })
  if review.base and review.head then
    lines[#lines + 1] = "Git command: git diff --find-renames --no-ext-diff " .. tostring(review.base) .. " " .. tostring(review.head)
  else
    lines[#lines + 1] = "The comparison was captured from Diffview; inspect the listed files and current repository without modifying them."
    if review.base then lines[#lines + 1] = "Git command: git diff --find-renames --no-ext-diff " .. tostring(review.base) end
  end
  lines[#lines + 1] = "Captured files:"
  for _, change in ipairs(review.changes or {}) do
    local before = type(change.before_blob) == "table" and change.before_blob.hash or "null"
    local after = type(change.after_blob) == "table" and change.after_blob.hash or "null"
    lines[#lines + 1] = string.format("- %s (%s, before=%s, after=%s)", change.path, change.operation or "modified", before, after)
  end
  return table.concat(lines, "\n")
end

function M.parse(response, review)
  local payload = tostring(response or ""):match("```lazyagent%-review%s*\n(.-)\n```")
  if not payload then return nil, "AI response has no lazyagent-review block" end
  local decode = vim.json and vim.json.decode or vim.fn.json_decode
  local ok, decoded = pcall(decode, payload)
  if not ok or type(decoded) ~= "table" then return nil, "AI review block is not valid JSON" end
  if tostring(decoded.review_id or "") ~= tostring(review.review_id) then return nil, "AI review ID does not match" end
  local paths = {}
  for _, change in ipairs(review.changes or {}) do paths[change.path] = change end
  local annotations = {}
  for _, finding in ipairs(type(decoded.findings) == "table" and decoded.findings or {}) do
    local label = tostring(finding.label or "imo"):lower()
    local path = tostring(finding.path or "")
    local change = paths[path]
    local side = tostring(finding.side or "after"):lower()
    local line = tonumber(finding.line)
    local end_line = tonumber(finding.end_line or finding.line)
    local summary = vim.trim(tostring(finding.summary or ""))
    local rationale = vim.trim(tostring(finding.rationale or ""))
    local ref = change and (side == "before" and change.before_blob or change.after_blob) or nil
    local target_ok = side == "overall" and path == ""
      or side == "file" and change ~= nil
      or (change ~= nil and ref ~= nil and change.binary ~= true
        and (side == "before" or side == "after") and line and line > 0)
    if allowed_labels[label] and target_ok and (summary ~= "" or rationale ~= "") then
      annotations[#annotations + 1] = {
        kind = "review",
        label = label,
        summary = summary ~= "" and summary or nil,
        rationale = rationale ~= "" and rationale or nil,
        path = change and change.path or nil,
        target = {
          side = side,
          start_line = line and math.floor(line) or nil,
          end_line = end_line and math.max(math.floor(line or end_line), math.floor(end_line)) or nil,
          blob_hash = type(ref) == "table" and ref.hash or nil,
        },
        author = { type = "agent", name = "AI Reviewer" },
        created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      }
    end
  end
  return annotations
end

return M
