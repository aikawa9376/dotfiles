local M = {}

local THREAD_ID = "123e4567-e89b-42d3-a456-426614174020"

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run()
  local base = vim.fn.tempname() .. "-blob-gc"
  local BlobStore = require("lazyagent.acp.blob_store")
  local ThreadStore = require("lazyagent.acp.thread_store")
  local BlobGC = require("lazyagent.acp.blob_gc")
  local blobs = BlobStore.new({ dir = base .. "/blobs", max_blob_bytes = false })
  local protected = assert(blobs:put("protected"))
  local old_orphan = assert(blobs:put("old orphan"))
  local unconfirmed = assert(blobs:put("unconfirmed orphan"))
  local recent = assert(blobs:put("recent orphan"))
  local uv = vim.uv or vim.loop
  assert(uv.fs_utime(blobs:_path(old_orphan.hash), 800, 800))
  assert(uv.fs_utime(blobs:_path(unconfirmed.hash), 800, 800))
  assert(uv.fs_utime(blobs:_path(recent.hash), 950, 950))

  local threads = ThreadStore.new({ dir = base .. "/threads" })
  assert(threads:create({
    thread_id = THREAD_ID,
    provider_id = "fixture",
    cwd = base,
    status = "closed",
    change_journal = {
      turns = { {
        turn_id = THREAD_ID .. ":1",
        state = "completed",
        changes = { {
          path = "fixture.txt",
          operation = "modified",
          before_blob = protected,
          after_blob = protected,
        } },
      } },
    },
  }))

  local gc = BlobGC.new({
    base_dir = base,
    thread_store = threads,
    min_age_seconds = 100,
    now = function() return 1000 end,
  })
  local report = assert(gc:scan())
  assert_equal(report.stored_count, 4, "stored blob count")
  assert_equal(report.referenced_count, 1, "deduplicated manifest references")
  assert_equal(report.orphan_count, 3, "orphan blob count")
  assert_equal(report.eligible_count, 2, "old orphan count")
  assert_equal(report.recent_count, 1, "grace-period orphan count")
  assert_equal(report.blocked, false, "closed thread allows GC")
  assert(gc:report_lines(report)[3]:match("dry run"), "report identifies dry run")

  local swept = assert(gc:sweep({ old_orphan.hash }))
  assert_equal(swept.deleted_count, 1, "confirmed orphan deletion")
  assert_equal(vim.fn.filereadable(blobs:_path(old_orphan.hash)), 0, "confirmed orphan removed")
  assert_equal(vim.fn.filereadable(blobs:_path(unconfirmed.hash)), 1, "unconfirmed orphan retained")
  assert_equal(vim.fn.filereadable(blobs:_path(recent.hash)), 1, "recent orphan retained")
  assert_equal(assert(blobs:get(protected)), "protected", "referenced blob retained")

  assert(threads:update(THREAD_ID, {
    change_journal = {
      turns = { {
        turn_id = THREAD_ID .. ":rereferenced",
        state = "completed",
        changes = { {
          path = "rereferenced.txt",
          operation = "modified",
          before_blob = unconfirmed,
        } },
      } },
    },
  }))
  local rereferenced = assert(gc:sweep({ unconfirmed.hash }))
  assert_equal(rereferenced.deleted_count, 0, "newly referenced candidate is rechecked")
  assert_equal(rereferenced.skipped_count, 1, "newly referenced candidate is skipped")
  assert_equal(vim.fn.filereadable(blobs:_path(unconfirmed.hash)), 1, "newly referenced blob retained")

  assert(threads:update(THREAD_ID, { status = "active" }))
  local active_report = assert(gc:scan())
  assert_equal(active_report.blocked, true, "active thread blocks deletion")
  local active_sweep, active_err = gc:sweep({ unconfirmed.hash })
  assert_equal(active_sweep, nil, "active sweep result")
  assert_equal(active_err.code, "active_threads", "active sweep reason")
  assert_equal(vim.fn.filereadable(blobs:_path(unconfirmed.hash)), 1, "active sweep preserves orphan")

  assert(threads:update(THREAD_ID, {
    status = "closed",
    change_journal = {
      turns = { {
        turn_id = THREAD_ID .. ":2",
        state = "completed",
        changes = { {
          path = "missing.txt",
          operation = "modified",
          before_blob = { algorithm = "sha256", hash = string.rep("f", 64), size = 10 },
        } },
      } },
    },
  }))
  local missing_report = assert(gc:scan())
  assert_equal(#missing_report.missing_references, 1, "missing reference detected")
  assert_equal(missing_report.blocked, true, "missing reference blocks deletion")
  local missing_sweep, missing_err = gc:sweep({ unconfirmed.hash })
  assert_equal(missing_sweep, nil, "missing-reference sweep result")
  assert_equal(missing_err.code, "missing_references", "missing-reference sweep reason")
  assert_equal(vim.fn.filereadable(blobs:_path(unconfirmed.hash)), 1, "unsafe sweep preserves orphan")

  vim.fn.delete(base, "rf")
end

return M
