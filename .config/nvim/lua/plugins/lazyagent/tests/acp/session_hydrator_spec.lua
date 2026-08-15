local M = {}

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

local function thread(root, state)
  return {
    thread_id = "123e4567-e89b-42d3-a456-426614174000",
    provider_id = "fixture",
    cwd = root,
    transcript_path = root .. "/old-transcript.md",
    history_path = root .. "/old-history.jsonl",
    draft = "keep draft",
    unread = true,
    view_state = { topline = 8 },
    checkpoint = { state = "restored" },
    change_journal = { turns = { { turn_id = "old" } } },
    metadata = {
      title_source = "manual",
      activation = { schema_version = 1, origin = "native_import", history_state = state, history_source = "none" },
    },
  }
end

local function updates(include_tool)
  local values = {
    { sessionUpdate = "user_message_chunk", messageId = "replay-user-1", content = { type = "text", text = "older " } },
    { sessionUpdate = "user_message_chunk", messageId = "replay-user-1", content = { type = "text", text = "question" } },
    { sessionUpdate = "agent_message_chunk", messageId = "replay-agent-1", content = { type = "text", text = "older " } },
    { sessionUpdate = "agent_message_chunk", messageId = "replay-agent-1", content = { type = "text", text = "answer" } },
  }
  if include_tool then
    values[#values + 1] = { sessionUpdate = "tool_call", toolCallId = "replay-tool-1", kind = "edit", status = "pending" }
    values[#values + 1] = { sessionUpdate = "tool_call_update", toolCallId = "replay-tool-1", kind = "edit", status = "completed" }
  end
  values[#values + 1] = { sessionUpdate = "session_info_update", title = "Replayed native session" }
  return values
end

local function feed(hydrator, values)
  for _, update in ipairs(values) do
    assert(hydrator:consume({ sessionId = "native", update = update }))
  end
end

local function new_hydrator(Hydrator, root, state, opts)
  opts = opts or {}
  opts.thread = opts.thread or thread(root, state)
  opts.base_session = opts.base_session or {
    transcript_path = root .. "/live.md",
    conversation_timeline = { { kind = "user", body = "live" } },
    tool_timeline = { { toolCallId = "live-tool" } },
    active_change_journal = { turns = { { turn_id = "live" } } },
    view = { identity = "live-view" },
  }
  opts.cache_dir = root
  return Hydrator.new(opts), opts.base_session
end

function M.run()
  local Hydrator = require("lazyagent.acp.session_hydrator")
  local StructuredHistory = require("lazyagent.acp.structured_history")
  local root = vim.fn.tempname() .. "-session-hydrator"
  vim.fn.mkdir(root, "p")
  vim.fn.writefile({ "old transcript" }, root .. "/old-transcript.md")
  assert(StructuredHistory.write(root .. "/old-history.jsonl", { { schema_version = 1, turn_id = "old" } }))

  local first, base = new_hydrator(Hydrator, root, "missing")
  assert(first:begin())
  feed(first, updates(true))
  local artifact = assert(first:prepare())
  assert_equal(artifact.conversation_timeline[1].body, "older question", "HYDRATE-01 replay user normalized once")
  assert_equal(artifact.conversation_timeline[2].body, "older answer", "HYDRATE-01 replay assistant normalized once")
  assert_equal(#artifact.conversation_timeline, 2, "HYDRATE-02 message IDs combine chunks")
  assert_equal(base.conversation_timeline[1].body, "live", "collector state is disjoint from live conversation")
  assert_equal(base.tool_timeline[1].toolCallId, "live-tool", "collector state is disjoint from live tools")
  assert_equal(artifact.structured_records[1].changes, {}, "HYDRATE-04 replay tools create no file changes")
  assert_equal(artifact.structured_records[1].tools[1].status, "completed", "HYDRATE-04 historical edit is retained")

  local independent = new_hydrator(Hydrator, root, "missing")
  assert(independent:begin())
  feed(independent, updates(false))
  local second_artifact = assert(independent:prepare())
  assert(artifact.generation_id ~= second_artifact.generation_id, "HYDRATE-03 generations are independent")
  assert_equal(second_artifact.conversation_timeline[1].body, "older question", "HYDRATE-03 repeated replay remains complete")

  local complete = new_hydrator(Hydrator, root, "complete")
  assert(complete:begin())
  feed(complete, updates(false))
  local complete_calls = 0
  local complete_result = assert(complete:publish(function() complete_calls = complete_calls + 1 end))
  assert_equal(complete_calls, 0, "HYDRATE-05 complete local history is not republished")
  assert_equal(complete_result.transcript_path, root .. "/old-transcript.md", "HYDRATE-05 transcript path unchanged")
  assert_equal(complete_result.history_path, root .. "/old-history.jsonl", "HYDRATE-05 history path unchanged")

  local missing = new_hydrator(Hydrator, root, "missing")
  assert(missing:begin())
  feed(missing, updates(false))
  local published_changes, published_opts, publication_calls = nil, nil, 0
  local missing_result = assert(missing:publish(function(changes, opts)
    publication_calls = publication_calls + 1
    published_changes, published_opts = vim.deepcopy(changes), vim.deepcopy(opts)
    return vim.tbl_deep_extend("force", thread(root, "missing"), changes)
  end))
  assert_equal(publication_calls, 1, "HYDRATE-06 one atomic publication")
  assert(published_changes.transcript_path ~= root .. "/old-transcript.md", "HYDRATE-06 new transcript generation")
  assert(published_changes.history_path ~= root .. "/old-history.jsonl", "HYDRATE-06 new history generation")
  assert_equal(published_opts.replace_metadata, true, "HYDRATE-06 exact metadata publication")
  assert_equal(vim.fn.filereadable(missing_result.transcript_path), 1, "HYDRATE-06 transcript validates")
  assert_equal(#assert(StructuredHistory.read(missing_result.history_path)), 1, "HYDRATE-06 structured history validates")
  assert_equal(bit.band(assert((vim.uv or vim.loop).fs_stat(missing_result.transcript_path)).mode, 511), 384,
    "HYDRATE-06 transcript is 0600")

  local partial_thread = thread(root, "partial")
  local partial = new_hydrator(Hydrator, root, "partial", { thread = partial_thread })
  assert(partial:begin())
  feed(partial, updates(false))
  local partial_result = assert(partial:publish(function(changes)
    return vim.tbl_deep_extend("force", vim.deepcopy(partial_thread), changes)
  end))
  for _, key in ipairs({ "draft", "unread", "view_state", "checkpoint", "change_journal" }) do
    assert_equal(partial_result[key], partial_thread[key], "HYDRATE-07 preserves " .. key)
  end
  assert_equal(partial_result.metadata.title_source, "manual", "HYDRATE-07 preserves unrelated metadata")

  local empty = new_hydrator(Hydrator, root, "missing")
  assert(empty:begin())
  local empty_changes
  local empty_result = assert(empty:publish(function(changes)
    empty_changes = vim.deepcopy(changes)
    return vim.tbl_deep_extend("force", thread(root, "missing"), changes)
  end))
  assert_equal(empty_changes.transcript_path, nil, "HYDRATE-08 empty replay publishes no transcript")
  assert_equal(empty_changes.history_path, nil, "HYDRATE-08 empty replay publishes no history")
  assert_equal(empty_result.metadata.activation.last_warning, "empty_replay", "HYDRATE-08 empty replay warning")

  local write_failure = new_hydrator(Hydrator, root, "missing", {
    write_transcript = function() return nil, "injected transcript failure" end,
  })
  assert(write_failure:begin())
  feed(write_failure, updates(false))
  local failed, failed_err = write_failure:publish(function() error("must not publish") end)
  assert_equal(failed, nil, "HYDRATE-09 staging failure result")
  assert(tostring(failed_err):find("injected transcript failure", 1, true), "HYDRATE-09 staging failure diagnostic")
  assert_equal(write_failure:snapshot().owned_file_count, 0, "HYDRATE-09 failed staging cleans owned files")
  assert_equal(vim.fn.filereadable(root .. "/old-transcript.md"), 1, "HYDRATE-09 old transcript retained")

  local publish_failure = new_hydrator(Hydrator, root, "missing")
  assert(publish_failure:begin())
  feed(publish_failure, updates(false))
  local rejected, rejected_err = publish_failure:publish(function() return nil, "injected publication failure" end)
  assert_equal(rejected, nil, "HYDRATE-10 publication failure result")
  assert_equal(rejected_err, "injected publication failure", "HYDRATE-10 publication failure diagnostic")
  assert_equal(vim.fn.filereadable(root .. "/old-history.jsonl"), 1, "HYDRATE-10 old history retained")
  assert(publish_failure:discard("rollback"))
  assert(publish_failure:discard("rollback again"))
  assert_equal(publish_failure:snapshot().owned_file_count, 0, "HYDRATE-11 repeated discard is idempotent")

  assert_equal(artifact.history_update_count, 6, "HYDRATE-12 every history update before prepare is collected")
  local after_publish, after_publish_err = missing:consume({ update = {
    sessionUpdate = "agent_message_chunk", messageId = "late", content = { type = "text", text = "late" },
  } })
  assert_equal(after_publish, nil, "HYDRATE-13 closed collector rejects live update")
  assert(tostring(after_publish_err):find("not collecting", 1, true), "HYDRATE-13 live update diagnostic")

  for _, method in ipairs({ "fs/read_text_file", "fs/write_text_file", "terminal/create", "session/request_permission" }) do
    local _, host_err = missing:reject_host_request(method)
    assert_equal(host_err.code, -32600, "HYDRATE-14 host request rejected: " .. method)
  end

  first:discard("done")
  independent:discard("done")
  complete:discard("done")
  missing:discard("published")
  partial:discard("published")
  empty:discard("done")
  vim.fn.delete(root, "rf")
end

return M
