local M = {}
local Review = require("lazyagent.acp.cockpit_review")
local LIMIT = 2 * 1024 * 1024

local function blob_state(ref)
  local digest = type(ref) == "table" and ref.hash
  if type(digest) == "string" and #digest == 64 and digest:match("^[a-f0-9]+$") then
    return { token = "blob:" .. digest, blob = { algorithm = "sha256", hash = digest } }
  end
  return { token = "unknown" }
end
local function absent() return { token = "deleted" } end
local function states(files)
  local result = {}
  for _, file in ipairs(files or {}) do
    local digest = tostring(file[2]):match("^blob:([a-f0-9]+)$")
    local state = blob_state({ hash = digest })
    if file[2] == "deleted" then state = absent() end
    result[file[1]] = state
  end
  return result
end

-- Compare recorded identities, never read the current workspace to invent history.
function M.plan(thread)
  local seen = thread.metadata and thread.metadata.cockpit_observation
  if type(seen) ~= "table" or seen.schema_version ~= 1 or seen.thread_id ~= thread.thread_id then
    return nil, "No checkpoint for this session. Press u in Cockpit first."
  end
  local code = type(seen.code) == "table" and seen.code.schema_version == 1 and seen.code or nil
  if code and code.root and code.root ~= thread.cwd then
    return nil, "This session's workspace changed after the checkpoint. Press u to record a new checkpoint."
  end
  local current = Review.snapshot(thread)
  local before, after = states(seen.files), states(current.files)
  local delta = Review.since(thread)
  local known, last_known = {}, 0
  for _, turn in ipairs(seen.turns or {}) do known[turn[1]] = true end
  for index, turn in ipairs(thread.change_journal and thread.change_journal.turns or {}) do
    if known[turn.turn_id] then last_known = index end
  end
  -- A path first changed in a later turn can use that turn's before blob.
  local inferred, touched = {}, {}
  local function first(path, state)
    if path and not touched[path] then inferred[path], touched[path] = state, true end
  end
  for index, turn in ipairs(thread.change_journal and thread.change_journal.turns or {}) do
    local later = not delta.history_gap and index > last_known and not known[turn.turn_id]
    for _, change in ipairs(turn.changes or {}) do
      local path = change.path or change.new_path or change.old_path
      local initial = (change.operation == "added" or change.operation == "moved") and absent() or blob_state(change.before_blob)
      first(path, later and initial or { token = "unknown" })
      if change.operation == "moved" and change.previous_path then
        first(change.previous_path, later and blob_state(change.before_blob) or { token = "unknown" })
      end
    end
    for path in pairs(turn.file_revisions or {}) do
      -- Missing before refs do not establish absence, especially for an active turn.
      first(path, { token = "unknown" })
    end
  end
  local paths = {}
  for path in pairs(before) do paths[path] = true end
  for path in pairs(after) do paths[path] = true end
  local changes = {}
  for path in pairs(paths) do
    local left = before[path] or inferred[path] or { token = "unknown" }
    local right = after[path] or { token = "unknown" }
    if left.token ~= right.token or left.token == "unknown" then
      local operation = left.token == "deleted" and "added" or right.token == "deleted" and "deleted" or "modified"
      changes[#changes + 1] = { path = path, operation = operation, before_blob = left.blob, after_blob = right.blob,
        inferred = before[path] == nil and left.token ~= "unknown",
        unavailable = (left.token == "unknown" or right.token == "unknown") and "Recorded before/after content is unavailable" or nil }
    end
  end
  table.sort(changes, function(a, b) return a.path < b.path end)
  return { observed_at = seen.observed_at, thread_id = thread.thread_id, changes = changes,
    history_gap = delta.history_gap == true, legacy = code == nil }
end

function M.read_pair(change, store)
  if change.unavailable then return nil, change.unavailable end
  local function size(ref) if not ref then return 0 end; return store:size(ref) end
  local left_size, left_err = size(change.before_blob)
  local right_size, right_err = size(change.after_blob)
  if left_size == nil or right_size == nil then return nil, "Saved blob missing: " .. tostring(left_err or right_err) end
  if left_size + right_size > LIMIT then return nil, "Diff omitted because the file pair exceeds 2 MiB" end
  local function read(ref)
    if not ref then return "" end
    local value, err = store:get(ref, { max_bytes = LIMIT })
    if not value then return nil, err end
    if vim.fn.sha256(value) ~= ref.hash then return nil, "Saved blob checksum mismatch" end
    return value
  end
  local before, before_err = read(change.before_blob)
  local after, after_err = read(change.after_blob)
  if before == nil or after == nil then return nil, before_err or after_err end
  return { before = before, after = after, binary = before:find("\0", 1, true) ~= nil or after:find("\0", 1, true) ~= nil }
end

local function label(value) return tostring(value or ""):gsub("%c", " ") end
function M.open(thread, store)
  local plan, err = M.plan(thread)
  if not plan then return nil, err end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "lazyagent://since-check/" .. thread.thread_id .. "/" .. tostring((vim.uv or vim.loop).hrtime()))
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = "nofile", "wipe", false
  vim.bo[buf].filetype = "lazyagent_changes"
  local expanded, failures, rows = {}, {}, {}
  local function render()
    local lines = { "LazyAgent · Changes since last check · " .. label(thread.title or thread.thread_id),
      "Checked: " .. label(plan.observed_at or "unknown") .. " · " .. #plan.changes .. " recorded file(s)",
      "o inline diff · <CR>/d before/after tab · q close",
      "Recorded code at open time; reopen gC to refresh. Unrecorded workspace edits are not included.", "" }
    if plan.history_gap then lines[#lines + 1] = "History was shortened or replaced; some comparisons are unavailable." end
    if plan.legacy then lines[#lines + 1] = "Older checkpoint: blobs may have been removed. u creates a checkpoint with retained references." end
    if #plan.changes == 0 then lines[#lines + 1] = "No recorded code differences since this checkpoint." end
    rows = {}
    for index, change in ipairs(plan.changes) do
      lines[#lines + 1] = string.format("%s %s", change.operation, label(change.path))
      rows[#lines] = index
      if change.inferred then
        lines[#lines + 1] = "  Before: first recorded change after checkpoint"
        rows[#lines] = index
      end
      local reason = failures[index] or change.unavailable
      if reason then lines[#lines + 1] = "  Unavailable: " .. label(reason); rows[#lines] = index end
      for _, line in ipairs(expanded[index] or {}) do lines[#lines + 1] = line; rows[#lines] = index end
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable, vim.bo[buf].modified = false, false
  end
  local function activate(inline)
    local index = rows[vim.api.nvim_win_get_cursor(0)[1]]
    if not index then return end
    if inline and expanded[index] then expanded[index] = nil; render(); return end
    local change = plan.changes[index]
    local pair, read_err = M.read_pair(change, store)
    if not pair then failures[index] = read_err; render(); return end
    if inline then
      if pair.binary then expanded[index] = { "Binary change: inline text diff is unavailable." }
      else
        local ok, diff = pcall(vim.diff, pair.before, pair.after, { result_type = "unified", algorithm = "histogram", ctxlen = 3 })
        if not ok then failures[index] = tostring(diff); render(); return end
        local lines = vim.split(diff, "\n", { plain = true, trimempty = true })
        if #lines > 500 then lines = vim.list_slice(lines, 1, 500); lines[#lines + 1] = "… diff truncated after 500 lines" end
        expanded[index] = #lines > 0 and lines or { "No textual difference." }
      end
      render()
    else
      -- Use existing immutable before/after buffers, with no decision/restore callbacks.
      local drawer = require("lazyagent.acp.change_review").new({ read_blob = function(ref)
        return ref.hash == (change.before_blob or {}).hash and pair.before or pair.after
      end })
      local shown = vim.deepcopy(change)
      shown.binary = pair.binary
      drawer.open_change(thread, { turn_id = "since-check:" .. thread.thread_id }, shown, index)
    end
  end
  render()
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, buf)
  vim.wo.number, vim.wo.relativenumber = false, false
  vim.keymap.set("n", "o", function() activate(true) end, { buffer = buf, desc = "Toggle changes since check inline diff" })
  for _, key in ipairs({ "<CR>", "d" }) do
    vim.keymap.set("n", key, function() activate(false) end, { buffer = buf, desc = "Compare saved code before/after" })
  end
  vim.keymap.set("n", "q", function() vim.cmd("close") end, { buffer = buf, nowait = true, desc = "Close comparison" })
  return true, buf
end
return M
