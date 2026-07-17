local M = {}

local uv = vim.uv or vim.loop
local DEFAULT_MIN_AGE_SECONDS = 24 * 60 * 60
local GC = {}
GC.__index = GC

local function valid_hash(value)
  return type(value) == "string" and #value == 64 and value:match("^[0-9a-f]+$") ~= nil
end

local function collect_references(value, references, seen)
  if type(value) ~= "table" or seen[value] then return end
  seen[value] = true
  if valid_hash(value.hash) and (value.algorithm == nil or value.algorithm == "sha256") then
    references[value.hash] = true
  end
  for _, child in pairs(value) do
    collect_references(child, references, seen)
  end
end

local function modified_seconds(stat)
  local modified = stat and stat.mtime or nil
  if type(modified) == "table" then return tonumber(modified.sec) end
  return tonumber(modified)
end

local function format_bytes(bytes)
  bytes = math.max(0, tonumber(bytes) or 0)
  if bytes < 1024 then return string.format("%d B", bytes) end
  local value, unit = bytes, "B"
  for _, candidate in ipairs({ "KiB", "MiB", "GiB", "TiB" }) do
    value = value / 1024
    unit = candidate
    if value < 1024 then break end
  end
  return string.format("%.1f %s", value, unit)
end

function GC:_blob_path(hash)
  return self.blob_dir .. "/sha256/" .. hash:sub(1, 2) .. "/" .. hash:sub(3)
end

function GC:_stored_blobs()
  local root = self.blob_dir .. "/sha256"
  local blobs = {}
  local prefixes = uv.fs_scandir(root)
  if not prefixes then return blobs end
  while true do
    local prefix, prefix_type = uv.fs_scandir_next(prefixes)
    if not prefix then break end
    if prefix_type == "directory" and prefix:match("^[0-9a-f][0-9a-f]$") then
      local directory = root .. "/" .. prefix
      local entries = uv.fs_scandir(directory)
      if entries then
        while true do
          local suffix, suffix_type = uv.fs_scandir_next(entries)
          if not suffix then break end
          local hash = prefix .. suffix
          if suffix_type == "file" and valid_hash(hash) then
            local path = directory .. "/" .. suffix
            local stat = uv.fs_lstat(path)
            if stat and stat.type == "file" then
              blobs[hash] = {
                hash = hash,
                path = path,
                size = tonumber(stat.size) or 0,
                modified_at = modified_seconds(stat),
              }
            end
          end
        end
      end
    end
  end
  return blobs
end

function GC:_report(manifest)
  local references = {}
  collect_references(manifest, references, {})
  local stored = self:_stored_blobs()
  local report = {
    scanned_at = self.now(),
    min_age_seconds = self.min_age_seconds,
    referenced_count = 0,
    stored_count = 0,
    stored_bytes = 0,
    orphan_count = 0,
    orphan_bytes = 0,
    eligible_count = 0,
    eligible_bytes = 0,
    recent_count = 0,
    recent_bytes = 0,
    active_thread_ids = {},
    missing_references = {},
    candidates = {},
  }
  for hash in pairs(references) do
    report.referenced_count = report.referenced_count + 1
    if not stored[hash] then report.missing_references[#report.missing_references + 1] = hash end
  end
  for _, thread in ipairs(manifest.threads or {}) do
    if thread.status == "active" then
      report.active_thread_ids[#report.active_thread_ids + 1] = thread.thread_id
    end
  end
  table.sort(report.active_thread_ids)
  table.sort(report.missing_references)
  for hash, blob in pairs(stored) do
    report.stored_count = report.stored_count + 1
    report.stored_bytes = report.stored_bytes + blob.size
    if not references[hash] then
      local age = blob.modified_at and math.max(0, report.scanned_at - blob.modified_at) or 0
      blob.age_seconds = age
      blob.eligible = blob.modified_at ~= nil and age >= self.min_age_seconds
      report.orphan_count = report.orphan_count + 1
      report.orphan_bytes = report.orphan_bytes + blob.size
      if blob.eligible then
        report.eligible_count = report.eligible_count + 1
        report.eligible_bytes = report.eligible_bytes + blob.size
      else
        report.recent_count = report.recent_count + 1
        report.recent_bytes = report.recent_bytes + blob.size
      end
      report.candidates[#report.candidates + 1] = blob
    end
  end
  table.sort(report.candidates, function(left, right)
    if left.eligible ~= right.eligible then return left.eligible == true end
    if left.size ~= right.size then return left.size > right.size end
    return left.hash < right.hash
  end)
  report.blocked = #report.active_thread_ids > 0 or #report.missing_references > 0
  return report
end

function GC:scan()
  local manifest, warning = self.thread_store:load()
  if not manifest then return nil, warning end
  if warning then return nil, warning end
  return self:_report(manifest)
end

function GC:sweep(expected_hashes)
  local expected = {}
  for key, value in pairs(type(expected_hashes) == "table" and expected_hashes or {}) do
    local hash = type(key) == "number" and value or key
    if valid_hash(hash) then expected[hash] = true end
  end
  if next(expected) == nil then return nil, "no confirmed blob hashes" end
  return self.thread_store:with_manifest_lock(function(manifest, warning)
    if warning then return nil, warning end
    local report = self:_report(manifest)
    if report.blocked then
      return nil, {
        code = #report.active_thread_ids > 0 and "active_threads" or "missing_references",
        active_thread_ids = report.active_thread_ids,
        missing_references = report.missing_references,
      }
    end
    local eligible = {}
    for _, candidate in ipairs(report.candidates) do
      if candidate.eligible then eligible[candidate.hash] = candidate end
    end
    local result = { deleted_count = 0, deleted_bytes = 0, skipped_count = 0, failures = {} }
    for hash in pairs(expected) do
      local candidate = eligible[hash]
      if not candidate then
        result.skipped_count = result.skipped_count + 1
      else
        local expected_path = self:_blob_path(hash)
        local stat = candidate.path == expected_path and uv.fs_lstat(expected_path) or nil
        if not stat or stat.type ~= "file" then
          result.skipped_count = result.skipped_count + 1
        else
          local deleted, delete_err = uv.fs_unlink(expected_path)
          if deleted then
            result.deleted_count = result.deleted_count + 1
            result.deleted_bytes = result.deleted_bytes + candidate.size
            pcall(uv.fs_rmdir, vim.fs.dirname(expected_path))
          else
            result.failures[#result.failures + 1] = { hash = hash, error = delete_err }
          end
        end
      end
    end
    return result
  end)
end

function GC:report_lines(report)
  local lines = {
    "LazyAgent ACP Blob GC",
    "",
    "This report is a dry run. No files have been deleted.",
    string.format("Stored: %d blob(s), %s", report.stored_count, format_bytes(report.stored_bytes)),
    string.format("Referenced: %d blob(s)", report.referenced_count),
    string.format("Orphaned: %d blob(s), %s", report.orphan_count, format_bytes(report.orphan_bytes)),
    string.format(
      "Eligible (at least %.1fh old): %d blob(s), %s",
      report.min_age_seconds / 3600,
      report.eligible_count,
      format_bytes(report.eligible_bytes)
    ),
    string.format("Grace period: %d recent blob(s), %s", report.recent_count, format_bytes(report.recent_bytes)),
  }
  if report.blocked then
    lines[#lines + 1] = ""
    if #report.active_thread_ids > 0 then
      lines[#lines + 1] = "Deletion blocked: active threads exist. Close them and scan again."
      for _, thread_id in ipairs(report.active_thread_ids) do lines[#lines + 1] = "- " .. thread_id end
    else
      lines[#lines + 1] = "Deletion blocked: referenced blobs are missing; inspect the thread manifest first."
    end
  end
  if #report.missing_references > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("Warning: %d referenced blob(s) are already missing.", #report.missing_references)
  end
  if #report.candidates > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Candidates:"
    for index, candidate in ipairs(report.candidates) do
      if index > 200 then
        lines[#lines + 1] = string.format("- ... and %d more", #report.candidates - 200)
        break
      end
      lines[#lines + 1] = string.format(
        "- %s  %s  %s",
        candidate.eligible and "eligible" or "grace",
        format_bytes(candidate.size),
        candidate.hash
      )
    end
  end
  return lines
end

function GC:open_report(report)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, "lazyagent://acp/blob-gc/" .. tostring(bufnr))
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, self:report_lines(report))
  vim.bo[bufnr].filetype = "markdown"
  vim.bo[bufnr].modifiable = false
  vim.cmd("botright new")
  vim.api.nvim_win_set_buf(0, bufnr)
  return bufnr
end

function M.new(opts)
  opts = opts or {}
  local base = tostring(opts.base_dir or (vim.fn.stdpath("cache") .. "/lazyagent/acp"))
  local ThreadStore = require("lazyagent.acp.thread_store")
  return setmetatable({
    blob_dir = tostring(opts.blob_dir or (base .. "/blobs")),
    thread_store = opts.thread_store or ThreadStore.new({ dir = opts.thread_dir or (base .. "/threads") }),
    min_age_seconds = math.max(0, tonumber(opts.min_age_seconds) or DEFAULT_MIN_AGE_SECONDS),
    now = opts.now or os.time,
  }, GC)
end

M.DEFAULT_MIN_AGE_SECONDS = DEFAULT_MIN_AGE_SECONDS
M.format_bytes = format_bytes

return M
