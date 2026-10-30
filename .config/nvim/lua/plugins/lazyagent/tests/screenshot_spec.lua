local M = {}

function M.run()
  local state = require("lazyagent.logic.state")
  local image = require("lazyagent.logic.image_paste")
  local session = require("lazyagent.logic.session")
  local previous = {
    opts = state.opts, system = vim.system, defer = vim.defer_fn, notify = vim.notify,
    executable = vim.fn.executable, has = vim.fn.has, start = session.start_interactive_session,
    wayland = vim.env.WAYLAND_DISPLAY, display = vim.env.DISPLAY, session_type = vim.env.XDG_SESSION_TYPE,
    buf = vim.api.nvim_get_current_buf(),
  }
  local directory = vim.fn.tempname() .. "-screenshot"
  local buf = vim.api.nvim_create_buf(false, true)
  local other = vim.api.nvim_create_buf(false, true)
  local closed
  local captures, timers, notices = {}, {}, {}
  local ok, err = xpcall(function()
    state.opts = { image_paste = {
      enabled = true, dir = directory, dir_layout = "flat", max_dimension = 0,
      notify = false, preview = { enabled = false },
    } }
    vim.env.WAYLAND_DISPLAY = nil
    vim.env.XDG_SESSION_TYPE = "x11"
    vim.env.DISPLAY = ":fixture"
    vim.fn.has = function(name)
      if name == "macunix" or name == "win32" or name == "win64" then return 0 end
      return previous.has(name)
    end
    vim.fn.executable = function(name) return name == "import" and 1 or previous.executable(name) end
    vim.notify = function(message) notices[#notices + 1] = message end
    vim.defer_fn = function(callback, ms) timers[#timers + 1] = { callback = callback, ms = ms } end
    vim.system = function(argv)
      assert(argv[1] == "import", "only the fake screenshot backend may run")
      captures[#captures + 1] = argv
      return { wait = function()
        vim.fn.writefile({ "screenshot fixture" }, argv[2])
        return { code = 0, stdout = "", stderr = "" }
      end }
    end
    vim.b[buf].lazyagent_is_scratch = true
    vim.api.nvim_set_current_buf(buf)
    local done = false
    assert(image.screenshot_into_buffer(buf, "5", function(path) done = path end) == true)
    assert(#captures == 0 and done == false, "delay returns before starting screen selection")
    assert(timers[1].ms == 5000, "delay is scheduled in milliseconds")
    vim.api.nvim_set_current_buf(other)
    timers[1].callback()
    assert(type(done) == "string" and vim.fn.filereadable(done) == 1, "delayed screenshot completes")
    assert(vim.api.nvim_get_current_buf() == other, "capture does not steal current buffer")
    assert(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "@" .. done, "capture attaches to original scratch")
    assert(vim.api.nvim_buf_get_lines(other, 0, -1, false)[1] == "", "other buffer is untouched")

    local immediate = assert(image.screenshot_into_buffer(buf))
    assert(type(immediate) == "string" and #captures == 2, "no argument captures immediately")
    assert(#timers == 1, "immediate screenshot creates no timer")
    assert(type(image.screenshot_into_buffer(buf, 0)) == "string", "zero captures immediately")
    for _, invalid in ipairs({ "", "later", "-1", "nan", "1e999", math.huge }) do
      local count = #captures
      assert(image.screenshot_into_buffer(buf, invalid) == nil, "invalid delay is rejected: " .. tostring(invalid))
      assert(#captures == count and #timers == 1, "invalid delay starts neither capture nor timer")
    end

    closed = vim.api.nvim_create_buf(false, true)
    local cancelled = false
    image.screenshot_into_buffer(closed, 5, function(path) cancelled = path == nil end)
    vim.api.nvim_buf_delete(closed, { force = true })
    local count = #captures
    timers[#timers].callback()
    assert(cancelled and #captures == count, "closing target before timeout skips capture")

    -- Exercise the real global command, retaining legacy agent-only syntax.
    local commands = {}
    require("lazyagent.commands.image").register(function(name, callback, opts)
      commands[name] = { callback = callback, opts = opts }
    end)
    local screenshot = commands.LazyAgentScreenShot
    assert(screenshot.opts.nargs == "*", "global command accepts delay and agent")
    vim.api.nvim_set_current_buf(buf)
    screenshot.callback({ args = "2.5" })
    assert(timers[#timers].ms == 2500, "global command forwards seconds")
    timers[#timers].callback()
    local opened
    session.start_interactive_session = function(opts)
      opened = opts.agent_name
      vim.api.nvim_set_current_buf(buf)
    end
    for _, args in ipairs({ "Codex", "5 Codex", "Codex 5" }) do
      screenshot.callback({ args = args })
      assert(opened == "Codex", "explicit agent routing: " .. args)
      assert(timers[#timers].ms == 80, "explicit agent waits for scratch opening")
      timers[#timers].callback()
      if args ~= "Codex" then
        assert(timers[#timers].ms == 5000, "agent command forwards delay: " .. args)
        timers[#timers].callback()
      end
    end
    local timer_count = #timers
    screenshot.callback({ args = "Codex invalid" })
    screenshot.callback({ args = "5 Codex extra" })
    assert(#timers == timer_count, "invalid command arguments do not open scratch or schedule capture")

    -- The scratch-local command shadows the global command and must accept
    -- the same delay when invoked from its normal user entry point.
    require("lazyagent.logic.keymaps").register_scratch_keymaps(buf, {
      agent_name = "Codex", agent_cfg = {}, source_bufnr = other,
    })
    vim.cmd("LazyAgentScreenShot 3")
    assert(timers[#timers].ms == 3000, "scratch-local command accepts delay seconds")
    timers[#timers].callback()
    vim.cmd("LazyAgentScreenShot")
    assert(#timers == timer_count + 1, "scratch-local no-argument capture stays immediate")
  end, debug.traceback)

  for _, target in ipairs({ buf, other }) do
    image.clear_buffer_previews(target)
  end
  state.opts, vim.system, vim.defer_fn, vim.notify = previous.opts, previous.system, previous.defer, previous.notify
  vim.fn.executable, vim.fn.has = previous.executable, previous.has
  session.start_interactive_session = previous.start
  vim.env.WAYLAND_DISPLAY, vim.env.DISPLAY, vim.env.XDG_SESSION_TYPE = previous.wayland, previous.display, previous.session_type
  vim.api.nvim_set_current_buf(previous.buf)
  for _, target in ipairs({ buf, other, closed }) do
    if target and vim.api.nvim_buf_is_valid(target) then vim.api.nvim_buf_delete(target, { force = true }) end
  end
  vim.fn.delete(directory, "rf")
  if not ok then error(err) end
end

return M
