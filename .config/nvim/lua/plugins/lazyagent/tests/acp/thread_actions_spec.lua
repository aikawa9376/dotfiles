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
  local changes_thread_id
  local create_request
  local state = { backends = {}, editor_instance_id = "test-nvim" }
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
  function backend.get_view_snapshot()
    return {
      source = "buffer",
      lines = { "# User", "live prompt", "", "# Assistant", "live mirror" },
      line_count = 5,
      changedtick = 7,
    }
  end
  function backend.show_thread_changes(thread_id)
    changes_thread_id = thread_id
    return records[thread_id] ~= nil
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
    editor_registry = {
      targets = function(root)
        return { { instance_id = "target-nvim", label = "Target Neovim", roots = { root } } }
      end,
      request_create_agent = function(target, provider, root)
        create_request = { target = target, provider = provider, root = root }
        return true
      end,
    },
  })

  assert_equal(actions.new_thread("Codex"), true, "new thread action")
  assert_equal(opened.agent_name, "Codex", "new thread provider")
  assert_equal(opened.acp_thread_id, THREAD_ID, "new thread open UUID")
  assert_equal(actions.new_thread_in_workspace("Codex", "/tmp"), true, "workspace thread action")
  assert_equal(records[THREAD_ID].cwd, "/tmp", "workspace thread cwd")
  assert_equal(actions.request_new_agent("/tmp", "Codex"), true, "remote new agent request")
  assert_equal(create_request.provider, "Codex", "remote new agent provider")
  assert_equal(create_request.root, "/tmp", "remote new agent workspace")
  assert_equal(actions.rename_thread(THREAD_ID, "Renamed"), true, "rename thread action")
  assert_equal(records[THREAD_ID].title, "Renamed", "renamed thread title")
  assert_equal(actions.archive_thread(THREAD_ID), true, "archive thread action")
  assert_equal(records[THREAD_ID].status, "archived", "archived thread status")
  assert_equal(actions.restore_thread(THREAD_ID), true, "restore thread action")
  assert_equal(records[THREAD_ID].status, "closed", "restored thread status")

  local workspace = vim.fn.tempname() .. "-thread-workspace"
  vim.fn.mkdir(workspace, "p")
  local source_path = workspace .. "/source.lua"
  vim.fn.writefile({ "return true" }, source_path)
  records[THREAD_ID].cwd = workspace
  records[THREAD_ID].metadata = { editor = { source_path = source_path } }
  opened = nil
  assert_equal(actions.open_thread(THREAD_ID), true, "open closed workspace thread")
  assert_equal(opened.root_dir, workspace, "closed thread keeps persisted workspace")
  assert_equal(vim.api.nvim_buf_get_name(opened.source_bufnr), source_path, "closed thread restores source anchor")

  local FOREIGN_ID = "123e4567-e89b-42d3-a456-426614174099"
  records[THREAD_ID].change_journal = { turns = { { changes = { { path = "source.lua" } } } } }
  records[THREAD_ID].metadata.editor.owner_pid = vim.fn.getpid()
  records[THREAD_ID].metadata.editor.instance_id = "test-nvim"
  records[FOREIGN_ID] = {
    thread_id = FOREIGN_ID,
    provider_id = "Codex",
    title = "Foreign changes",
    cwd = "/tmp/foreign",
    status = "closed",
    metadata = { editor = { instance_id = "other-nvim", owner_pid = vim.fn.getpid() + 1 } },
    change_journal = { turns = { { changes = { { path = "foreign.lua" } } } } },
  }
  local selected_threads
  local previous_select = vim.ui.select
  rawset(vim.ui, "select", function(items) selected_threads = items end)
  changes_thread_id = nil
  assert_equal(actions.show_thread_changes(), true, "show current Neovim changes")
  assert_equal(selected_threads, nil, "single changed thread skips picker")
  assert_equal(changes_thread_id, THREAD_ID, "single changed thread opens directly")

  local SECOND_ID = "123e4567-e89b-42d3-a456-426614174098"
  records[SECOND_ID] = {
    thread_id = SECOND_ID,
    provider_id = "Codex",
    title = "Second local changes",
    cwd = workspace,
    status = "closed",
    metadata = { editor = { instance_id = "test-nvim", owner_pid = vim.fn.getpid() } },
    change_journal = { turns = { { changes = { { path = "second.lua" } } } } },
  }
  selected_threads = nil
  assert_equal(actions.show_thread_changes(), true, "show multiple current Neovim changes")
  rawset(vim.ui, "select", previous_select)
  assert_equal(selected_threads and #selected_threads, 2, "multiple changed threads keep picker")
  records[SECOND_ID] = nil
  records[FOREIGN_ID] = nil

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
  records[THREAD_ID].status = "active"
  opened = nil
  assert_equal(actions.open_thread(THREAD_ID), false, "foreign live thread open guard")
  assert_equal(opened, nil, "foreign live thread does not launch duplicate")
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
  -- Sessions started without a pre-created thread keep their provider-only key,
  -- even after the ACP backend assigns a persisted thread UUID.
  local session_key = "Codex"
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
  assert_equal(opened.agent_name, session_key, "cockpit input reuses the exact runtime session key")
  assert_equal(opened.acp_thread_id, nil, "cockpit input does not derive a duplicate UUID session key")
  assert_equal(opened.window_type, "float", "cockpit input opens popup")
  assert_equal(opened.window_opts.height, 10, "cockpit input popup height")
  assert(vim.fn.maparg("]a", "n", false, true).buffer == 1, "cockpit next live mapping")
  assert(vim.fn.maparg("[a", "n", false, true).buffer == 1, "cockpit previous live mapping")
  assert(vim.fn.maparg("P", "n", false, true).buffer == 1, "cockpit preview toggle mapping")
  assert(vim.fn.maparg("<CR>", "n", false, true).buffer == 1, "cockpit mirror mapping")
  assert(vim.fn.maparg("o", "n", false, true).buffer == 1, "cockpit open mapping")
  opened = nil
  vim.cmd("normal \r")
  assert_equal(opened, nil, "cockpit mirror does not open or resume thread")
  local preview_found = false
  local cockpit_preview_bufnr
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local preview_buf = vim.api.nvim_win_get_buf(winid)
    if vim.bo[preview_buf].filetype == "markdown" and vim.api.nvim_buf_get_name(preview_buf):find("Cockpit Preview", 1, true) then
      preview_found = true
      cockpit_preview_bufnr = preview_buf
      assert_equal(
        table.concat(vim.api.nvim_buf_get_lines(preview_buf, 0, -1, false), "\n"),
        "# User\nlive prompt\n\n# Assistant\nlive mirror",
        "cockpit mirrors live ACP view text"
      )
      break
    end
  end
  assert_equal(preview_found, true, "cockpit transcript mirror window")
  vim.cmd("normal \r")
  local latest_lines = vim.api.nvim_buf_get_lines(cockpit_preview_bufnr, 0, -1, false)
  assert(table.concat(latest_lines, "\n"):find("ready", 1, true), "cockpit enter toggles back to latest response")

  local menu_items, menu_opts, menu_callback
  local menu_select = vim.ui.select
  vim.ui.select = function(items, opts, callback)
    menu_items, menu_opts, menu_callback = items, opts, callback
  end
  vim.cmd("normal ?")
  vim.ui.select = menu_select
  assert_equal(menu_opts.kind, "lazyagent-acp-actions", "cockpit action menu uses compact cursor UI")
  assert_equal(menu_items[1].key, "<CR>", "cockpit action menu lists preview toggle")
  opened = nil
  menu_callback(menu_items[1])
  assert_equal(opened, nil, "cockpit menu preview action does not open thread")
  local mirrored_lines = vim.api.nvim_buf_get_lines(cockpit_preview_bufnr, 0, -1, false)
  assert(table.concat(mirrored_lines, "\n"):find("live mirror", 1, true), "cockpit action menu executes selected action")
  vim.cmd("normal o")
  assert_equal(opened.acp_thread_id, THREAD_ID, "cockpit o opens exact thread")
  vim.cmd("tabclose")
  vim.fn.delete(cockpit_transcript_path)
  pcall(vim.api.nvim_buf_delete, vim.fn.bufnr(source_path), { force = true })
  vim.fn.delete(workspace, "rf")
end

return M
