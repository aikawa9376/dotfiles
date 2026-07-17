local M = {}

local THREAD_ID = "123e4567-e89b-42d3-a456-426614174000"

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run()
  local records = {}
  local opened
  local state = { backends = {} }
  local backend = {}
  state.backends.buffer_acp = backend
  function backend.get_thread(thread_id)
    return records[thread_id]
  end
  function backend.create_thread(attributes)
    local record = vim.tbl_extend("force", vim.deepcopy(attributes), {
      thread_id = THREAD_ID,
      status = "closed",
    })
    records[THREAD_ID] = record
    return vim.deepcopy(record)
  end
  function backend.archive_thread(thread_id)
    records[thread_id].status = "archived"
    return vim.deepcopy(records[thread_id])
  end
  function backend.restore_thread(thread_id)
    records[thread_id].status = "closed"
    return vim.deepcopy(records[thread_id])
  end
  function backend.rename_thread(thread_id, title)
    records[thread_id].title = title
    return vim.deepcopy(records[thread_id])
  end
  function backend.delete_thread(thread_id)
    records[thread_id] = nil
    return true
  end
  function backend.list_threads()
    return vim.tbl_values(records)
  end
  function backend.get_runtime_snapshot()
    return {
      acp_thread_id = THREAD_ID,
      acp_ready = true,
      acp_prompt_queue = {},
    }
  end

  local actions = require("lazyagent.logic.session.threads").setup({
    state = state,
    acp_logic = {
      is_acp_backend = function(name)
        return name == "buffer_acp"
      end,
    },
    agent_logic = {
      available_acp_agents = function()
        return { "Codex" }
      end,
      get_interactive_agent = function(provider_id)
        return provider_id == "Codex" and { acp = true } or nil
      end,
    },
    backend_logic = {
      resolve_backend_for_agent = function()
        return "buffer_acp", backend
      end,
    },
    start_interactive_session = function(opts)
      opened = opts
    end,
  })

  assert_equal(actions.new_thread("Codex"), true, "new thread action")
  assert_equal(opened.agent_name, "Codex", "new thread provider")
  assert_equal(opened.acp_thread_id, THREAD_ID, "new thread open UUID")
  assert_equal(actions.rename_thread(THREAD_ID, "Renamed"), true, "rename thread action")
  assert_equal(records[THREAD_ID].title, "Renamed", "renamed thread title")
  assert_equal(actions.archive_thread(THREAD_ID), true, "archive thread action")
  assert_equal(records[THREAD_ID].status, "archived", "archived thread status")
  assert_equal(actions.restore_thread(THREAD_ID), true, "restore thread action")
  assert_equal(records[THREAD_ID].status, "closed", "restored thread status")

  local transcript_path = vim.fn.tempname() .. "-thread-transcript.log"
  vim.fn.writefile({ "# User", "hello" }, transcript_path)
  records[THREAD_ID].transcript_path = transcript_path
  local tab_count = vim.fn.tabpagenr("$")
  assert_equal(actions.open_thread_transcript(THREAD_ID), true, "open persisted raw transcript")
  assert_equal(vim.fn.tabpagenr("$"), tab_count + 1, "raw transcript tab")
  assert_equal(vim.api.nvim_buf_get_name(0), transcript_path, "raw transcript path")
  assert_equal(vim.bo.filetype, "markdown", "raw transcript markdown filetype")
  assert_equal(vim.bo.readonly, true, "raw transcript readonly")
  assert_equal(vim.wo.wrap, false, "raw transcript nowrap")
  vim.cmd("tabclose")
  vim.fn.delete(transcript_path)

  records[THREAD_ID].process_id = 99
  assert_equal(actions.archive_thread(THREAD_ID), false, "active archive guard")
  assert_equal(actions.delete_thread(THREAD_ID), false, "active delete guard")
  local stale_transcript_path = vim.fn.tempname() .. "-stale-thread-transcript.log"
  vim.fn.writefile({ "# User", "stale" }, stale_transcript_path)
  records[THREAD_ID].transcript_path = stale_transcript_path
  assert_equal(actions.force_delete_thread(THREAD_ID), true, "force delete active record")
  assert_equal(records[THREAD_ID], nil, "force deleted thread record")
  assert_equal(vim.fn.filereadable(stale_transcript_path), 0, "force deleted thread transcript")

  local cockpit_transcript_path = vim.fn.tempname() .. "-cockpit-live-transcript.log"
  vim.fn.writefile({ "# User", "hello", "", "# Assistant", "ready" }, cockpit_transcript_path)
  records[THREAD_ID] = {
    thread_id = THREAD_ID,
    provider_id = "Codex",
    title = "Live thread",
    cwd = "/tmp/live",
    status = "active",
    process_id = 42,
    transcript_path = cockpit_transcript_path,
    metadata = { has_user_prompt = true },
  }
  local session_key = "Codex::" .. THREAD_ID
  state.sessions = {
    [session_key] = {
      pane_id = "acp:1",
      backend = "buffer_acp",
      provider_id = "Codex",
      thread_id = THREAD_ID,
    },
  }
  assert_equal(actions.open_cockpit(), true, "open interactive cockpit")
  local cockpit_bufnr = vim.api.nvim_get_current_buf()
  assert_equal(vim.bo[cockpit_bufnr].filetype, "lazyagent_acp_cockpit", "cockpit keeps focus beside preview")
  for line, text in ipairs(vim.api.nvim_buf_get_lines(cockpit_bufnr, 0, -1, false)) do
    if text:find("Live thread", 1, true) then
      vim.api.nvim_win_set_cursor(0, { line, 0 })
      break
    end
  end
  local input_map = vim.fn.maparg("i", "n", false, true)
  assert(input_map.buffer == 1, "cockpit live message mapping")
  vim.cmd("normal i")
  assert_equal(opened.acp_thread_id, THREAD_ID, "cockpit input routes exact thread")
  assert_equal(opened.window_type, "float", "cockpit input opens popup")
  assert_equal(opened.window_opts.height, 10, "cockpit input popup height")
  assert(vim.fn.maparg("]a", "n", false, true).buffer == 1, "cockpit next live mapping")
  assert(vim.fn.maparg("[a", "n", false, true).buffer == 1, "cockpit previous live mapping")
  assert(vim.fn.maparg("P", "n", false, true).buffer == 1, "cockpit preview toggle mapping")
  local preview_found = false
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local preview_buf = vim.api.nvim_win_get_buf(winid)
    if vim.bo[preview_buf].filetype == "markdown" and vim.api.nvim_buf_get_name(preview_buf):find("Cockpit Preview", 1, true) then
      preview_found = true
      break
    end
  end
  assert_equal(preview_found, true, "cockpit latest-response preview window")
  vim.cmd("tabclose")
  vim.fn.delete(cockpit_transcript_path)
end

return M
