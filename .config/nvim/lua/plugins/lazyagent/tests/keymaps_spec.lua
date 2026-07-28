local M = {}

local function assert_equal(expected, actual, label)
  if not vim.deep_equal(expected, actual) then
    error(string.format("%s: expected %s, got %s", label, vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

function M.run()
  local state = require("lazyagent.logic.state")
  local backend_logic = require("lazyagent.logic.backend")
  local keymaps = require("lazyagent.logic.keymaps")
  local previous_opts = state.opts
  local previous_sessions = state.sessions
  local previous_resolve = backend_logic.resolve_backend_for_agent
  local previous_keymap_set = vim.keymap.set
  local previous_notify = vim.notify
  local bufnr = vim.api.nvim_create_buf(false, true)
  local registered = {}
  local notices = {}
  local pending_callback
  local steer_calls = 0
  local supports_steering = true
  local cleared_draft = false

  local backend = {
    supports_steering = function() return supports_steering end,
    steer_active_turn = function(_, text, callback)
      steer_calls = steer_calls + 1
      pending_callback = callback
      assert(text:match("redirect"), "scratch steering text")
      return true
    end,
    get_runtime_snapshot = function()
      return { acp_thread_id = "thread-1" }
    end,
    set_thread_draft = function(_, value)
      cleared_draft = value == ""
      return true
    end,
  }

  local function cleanup()
    state.opts = previous_opts
    state.sessions = previous_sessions
    backend_logic.resolve_backend_for_agent = previous_resolve
    vim.keymap.set = previous_keymap_set
    vim.notify = previous_notify
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end

  local ok, err = xpcall(function()
    state.opts = {
      scratch_keymaps = {
        steer_normal = "<M-s>",
        steer_insert = "<M-s>",
      },
    }
    state.sessions = {
      TestAgent = {
        backend = "buffer_acp",
        pane_id = "pane-1",
      },
    }
    backend_logic.resolve_backend_for_agent = function()
      return "buffer_acp", backend
    end
    vim.keymap.set = function(mode, lhs, rhs)
      if lhs == "<M-s>" then registered[mode] = rhs end
    end
    vim.notify = function(message)
      notices[#notices + 1] = tostring(message)
    end

    keymaps.register_scratch_keymaps(bufnr, {
      agent_name = "TestAgent",
      agent_cfg = {},
      pane_id = "pane-1",
      reuse = true,
      source_bufnr = bufnr,
    })
    assert(type(registered.n) == "function", "normal scratch steering key")
    assert(type(registered.i) == "function", "insert scratch steering key")

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "redirect this turn" })
    registered.n()
    assert_equal(1, steer_calls, "scratch steering call count")
    assert_equal({ "redirect this turn" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "pending content")
    pending_callback(true, { outcome = "injected" })
    assert(vim.wait(200, function()
      return #vim.api.nvim_buf_get_lines(bufnr, 0, -1, false) == 1
        and vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1] == ""
    end, 5), "successful steering clears scratch")
    assert(cleared_draft, "successful steering clears persisted draft")

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "redirect but keep" })
    registered.n()
    pending_callback(false, { message = "steering failed" })
    assert(vim.wait(200, function()
      return vim.tbl_contains(notices, "LazyAgent ACP steering failed: steering failed")
    end, 5), "failed steering notification")
    assert_equal({ "redirect but keep" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "failed content")

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "redirect original" })
    registered.n()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "new draft" })
    pending_callback(true, { outcome = "injected" })
    assert(vim.wait(200, function()
      return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1] == "new draft"
    end, 5), "edited draft remains after steering response")

    supports_steering = false
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "unsupported redirect" })
    registered.n()
    assert_equal(3, steer_calls, "unsupported steering does not send")
    assert_equal({ "unsupported redirect" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "unsupported content")
  end, debug.traceback)

  cleanup()
  if not ok then error(err, 0) end
end

return M
