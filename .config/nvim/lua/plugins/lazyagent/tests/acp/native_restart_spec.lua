local M = {}

local function assert_equal(actual, expected, label)
  assert(vim.deep_equal(actual, expected), string.format(
    "%s\nexpected: %s\nactual:   %s",
    label,
    vim.inspect(expected),
    vim.inspect(actual)
  ))
end

function M.run()
  local NativeRestart = require("lazyagent.logic.session.native_restart")
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. "/acp/restart", "p")
  local opened = {}
  local started = {}
  local original_bufnr = vim.api.nvim_get_current_buf()
  local restored_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(restored_bufnr, "lazyagent://acp/Codex-buffer-acp-1")
  vim.api.nvim_win_set_buf(0, restored_bufnr)
  local sessions = {
    ["Codex::thread-a"] = {
      pane_id = "pane-a", backend = "buffer_acp", provider_id = "Codex", thread_id = "thread-a", hidden = false,
    },
    ["Gemini::thread-empty"] = {
      pane_id = "pane-empty", backend = "buffer_acp", provider_id = "Gemini", thread_id = "thread-empty", hidden = true,
      cwd = "/tmp/empty-workspace",
    },
    Shell = { pane_id = "pane-shell", backend = "tmux", hidden = false },
  }
  local backend = {
    get_runtime_snapshot = function(pane_id)
      if pane_id == "pane-empty" then
        return { acp_thread_id = "thread-empty", acp_process_id = 702, acp_has_user_prompt = false }
      end
      return { acp_thread_id = "thread-a", acp_process_id = 701, acp_has_user_prompt = true }
    end,
    get_thread = function(thread_id)
      if thread_id == "thread-empty" then return nil end
      return { thread_id = thread_id, metadata = { has_user_prompt = thread_id == "thread-a" } }
    end,
    capture_switch_view = function(pane_id)
      return { bufnr = restored_bufnr, pane_id = "buffer-acp-1", pane_config = { follow_output = false } }
    end,
  }
  local module = NativeRestart.setup({
    state = { sessions = sessions },
    acp_logic = { is_acp_backend = function(name) return name == "buffer_acp" end },
    backend_logic = { resolve_backend_for_agent = function() return "buffer_acp", backend end },
    cache_logic = { get_cache_dir = function() return root end },
    capture_scratch = function(session_key)
      if session_key ~= "Codex::thread-a" then return nil end
      return { was_open = true, text = "draft" }
    end,
    open_thread = function(thread_id, opts)
      opened[#opened + 1] = { thread_id = thread_id, opts = opts }
      opts.on_ready()
      return true
    end,
    start_session = function(opts)
      started[#started + 1] = opts
      opts.on_ready()
    end,
  })

  assert_equal(module.capture("quit"), false, "ordinary quit is ignored")
  assert_equal(module.capture("restart"), true, "native restart capture")
  local bundle_path = module.bundle_path()
  assert(vim.fn.filereadable(bundle_path) == 1, "restart bundle is written")
  assert_equal(module.restore("restart!"), false, "restart bang is ignored")
  assert_equal(module.restore("restart"), true, "native restart restore")
  assert(vim.wait(500, function() return #opened == 1 and #started == 1 end, 10), "thread restore callbacks")
  assert_equal(opened[1].thread_id, "thread-a", "same LazyAgent thread")
  assert_equal(opened[1].opts.restart_process_id, 701, "restart handoff process identity")
  assert_equal(opened[1].opts.open_input, true, "scratch visibility")
  assert_equal(opened[1].opts.initial_input, "draft", "scratch draft")
  assert_equal(opened[1].opts.reuse_view.bufnr, restored_bufnr, "restored transcript buffer")
  assert_equal(opened[1].opts.reuse_view.pane_id, "buffer-acp-1", "restored pane identity")
  assert_equal(opened[1].opts.reuse_view.preserve_existing_transcript, false, "restored transcript is hydrated")
  assert_equal(started[1].agent_name, "Gemini", "promptless provider restart")
  assert_equal(started[1].root_dir, "/tmp/empty-workspace", "promptless workspace restart")
  assert_equal(started[1].stay_hidden, true, "promptless hidden state")
  assert_equal(started[1].acp_reuse_view.bufnr, restored_bufnr, "promptless restored transcript buffer")
  assert_equal(started[1].acp_reuse_view.pane_id, "buffer-acp-1", "promptless restored pane identity")
  assert_equal(vim.fn.filereadable(bundle_path), 0, "restart bundle is consumed")

  vim.api.nvim_win_set_buf(0, original_bufnr)
  pcall(vim.api.nvim_buf_delete, restored_bufnr, { force = true })
  vim.fn.delete(root, "rf")
end

return M
