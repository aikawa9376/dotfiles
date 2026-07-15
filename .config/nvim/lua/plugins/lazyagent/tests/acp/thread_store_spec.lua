local M = {}

local THREAD_ID = "123e4567-e89b-42d3-a456-426614174000"

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run()
  local ThreadStore = require("lazyagent.acp.thread_store")
  local base = vim.fn.tempname() .. "-thread-store"
  local tick = 0
  local store = ThreadStore.new({
    dir = base,
    uuid = function()
      return THREAD_ID
    end,
    clock = function()
      tick = tick + 1
      return string.format("2026-07-15T00:00:%02dZ", tick)
    end,
  })

  local thread = assert(store:create({
    provider_id = "codex-acp",
    cwd = base .. "/workspace",
    additional_directories = { base .. "/shared", base .. "/shared" },
    native_session_id = "native-1",
    process_id = 42,
    transcript_path = base .. "/thread.log",
    config = { model = "gpt-5" },
  }))
  assert_equal(thread.thread_id, THREAD_ID, "local thread identity")
  assert_equal(thread.provider_id, "codex-acp", "provider identity")
  assert_equal(thread.native_session_id, "native-1", "native session identity")
  assert_equal(thread.process_id, 42, "process identity")
  assert_equal(#thread.additional_directories, 1, "additional directory normalization")
  assert_equal(thread.status, "active", "initial status")

  local manifest = assert(store:load())
  assert_equal(manifest.schema_version, ThreadStore.SCHEMA_VERSION, "manifest schema")
  assert_equal(#manifest.threads, 1, "persisted thread count")

  local reopened = ThreadStore.new({ dir = base })
  assert_equal(assert(reopened:get(THREAD_ID)).native_session_id, "native-1", "cross-instance load")
  assert_equal(#assert(reopened:list()), 1, "active thread listing")

  local renamed = assert(store:rename(THREAD_ID, "Persistent thread"))
  assert_equal(renamed.title, "Persistent thread", "rename")
  assert_equal(renamed.created_at, thread.created_at, "immutable creation timestamp")

  local archived = assert(store:archive(THREAD_ID))
  assert_equal(archived.status, "archived", "archive status")
  assert(archived.archived_at ~= nil, "archive timestamp")
  assert_equal(#assert(store:list()), 0, "archived threads hidden by default")
  assert_equal(#assert(store:list({ include_archived = true })), 1, "archived thread listing")

  local restored = assert(store:restore(THREAD_ID))
  assert_equal(restored.status, "closed", "restored status")
  assert_equal(restored.archived_at, nil, "restored archive timestamp")

  local deleted, deleted_record = store:delete(THREAD_ID)
  assert_equal(deleted, true, "delete result")
  assert_equal(deleted_record.thread_id, THREAD_ID, "deleted record")
  assert_equal(#assert(store:list({ include_archived = true })), 0, "deleted thread listing")

  vim.fn.writefile({ "not-json" }, store.path)
  local recovered, warning = store:load()
  assert_equal(#recovered.threads, 0, "corrupt manifest recovery")
  assert_equal(warning.code, "corrupt_manifest", "corrupt manifest warning")
  assert(vim.fn.filereadable(warning.quarantined_path) == 1, "corrupt manifest should be quarantined")

  vim.fn.writefile({ vim.fn.json_encode({ schema_version = 99, threads = {} }) }, store.path)
  local unsupported, schema_err = store:load()
  assert_equal(unsupported, nil, "unsupported schema result")
  assert(tostring(schema_err):match("unsupported thread manifest schema"), "unsupported schema error")
  assert_equal(vim.fn.filereadable(store.path), 1, "newer schema should not be quarantined")

  assert_equal(ThreadStore.valid_uuid(THREAD_ID), true, "valid UUID v4")
  assert_equal(ThreadStore.valid_uuid("1-2-4-8-5"), false, "malformed UUID v4")

  vim.fn.delete(base, "rf")
end

return M
