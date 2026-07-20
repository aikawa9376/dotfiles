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

local function review_id(root, base, head)
  return vim.fn.sha256(table.concat({ root, base, head }, "\0")):sub(1, 20)
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
  return {
    schema_version = 1,
    review_id = review_id(root, base, head),
    root = root,
    range = range,
    mode = mode,
    base = base,
    head = head,
    created_at = created_at,
    status = "pending",
    changes = changes,
    annotations = {},
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
    "A finding may target an unchanged after-side line in a changed file when that surrounding code is directly relevant.",
    "Do not report unrelated pre-existing issues.",
    "Labels: must, should, imo, question, nit, praise.",
    "Your entire final response must be exactly one fenced block in this form:",
    "```lazyagent-review",
    '{"review_id":"' .. tostring(review.review_id) .. '","findings":[{"label":"must","path":"file.lua","line":12,"summary":"Short title","rationale":"Why this matters"}]}',
    "```",
    "The example finding only demonstrates the schema; do not copy it.",
    "Use after-side line numbers. Return an empty findings array when there are no findings.",
    "",
    "Repository root: " .. tostring(review.root),
    "Git range: " .. tostring(review.range),
    "Base: " .. tostring(review.base),
    "Head: " .. tostring(review.head),
    "Git command: git diff --find-renames --no-ext-diff " .. tostring(review.base) .. " " .. tostring(review.head),
  })
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
    local change = paths[tostring(finding.path or "")]
    local line = tonumber(finding.line)
    local summary = vim.trim(tostring(finding.summary or ""))
    local rationale = vim.trim(tostring(finding.rationale or ""))
    if allowed_labels[label] and change and line and line > 0 and (summary ~= "" or rationale ~= "") then
      annotations[#annotations + 1] = {
        kind = "review",
        label = label,
        summary = summary ~= "" and summary or nil,
        rationale = rationale ~= "" and rationale or nil,
        path = change.path,
        target = {
          side = "after", start_line = math.floor(line), end_line = math.floor(line),
          blob_hash = type(change.after_blob) == "table" and change.after_blob.hash or nil,
        },
        author = { type = "agent", name = "AI Reviewer" },
      }
    end
  end
  return annotations
end

return M
