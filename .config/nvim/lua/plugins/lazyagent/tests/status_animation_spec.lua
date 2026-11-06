local M = {}

function M.run()
  local uv = vim.uv or vim.loop
  local state = require("lazyagent.logic.state")
  local status = require("lazyagent.logic.status")
  local spinner = require("lazyagent.logic.status_spinner")
  spinner.stop()
  local previous = {
    sessions = state.sessions, timer = uv.new_timer, schedule = vim.schedule,
    redraw = vim.api.nvim__redraw, laststatus = vim.o.laststatus,
    statusline = vim.wo.statusline, lualine = package.loaded.lualine,
  }
  local handles, queue, redraws, refreshes = {}, {}, {}, 0
  local task
  local ok, err = xpcall(function()
    uv.new_timer = function()
      local handle = { stops = 0, closes = 0 }
      function handle:start(delay, interval, callback)
        assert(delay == 100 and interval == 100, "spinner uses a steady 100ms cadence")
        self.tick = callback
      end
      function handle:stop() self.stops = self.stops + 1 end
      function handle:close() self.closes = self.closes + 1 end
      handles[#handles + 1] = handle
      return handle
    end
    vim.schedule = function(callback) queue[#queue + 1] = callback end
    rawset(vim.api, "nvim__redraw", function(opts) redraws[#redraws + 1] = opts end)
    package.loaded.lualine = { refresh = function(opts)
      assert(vim.deep_equal(opts, { place = { "statusline" } }))
      refreshes = refreshes + 1
    end }
    vim.o.laststatus = 3
    state.sessions = { Codex = { pane_id = "fixture", provider_id = "Codex", agent_status = "thinking" } }
    local function render()
      return vim.api.nvim_eval_statusline(vim.wo.statusline, {}).str
    end
    local function drain()
      local callbacks = queue
      queue = {}
      for _, callback in ipairs(callbacks) do callback() end
    end
    vim.wo.statusline = status.get_statusline()
    local first = render()
    status.get_statusline()
    assert(#handles == 1, "repeated component evaluations share one timer")
    for _ = 1, 20 do handles[1].tick() end
    assert(#queue == 1, "busy editor coalesces pending ticks")
    drain()
    assert(render() ~= first, "native statusline expression advances without rerunning lualine")
    assert(vim.deep_equal(redraws, { { statusline = true } }), "tick only redraws statusline, without screen/cursor flush")
    assert(refreshes == 0, "animation does not refresh lualine components")
    local frames = { [render()] = true }
    for _ = 1, 9 do handles[1].tick(); drain(); frames[render()] = true end
    assert(vim.tbl_count(frames) == 10, "successive ticks show all ten frames without skipping")

    handles[1].tick()
    state.sessions.Codex.agent_status = "waiting"
    vim.wo.statusline = status.get_statusline()
    drain()
    assert(render() == " ?", "waiting replaces spinner")
    assert(#redraws == 10, "queued tick cannot redraw after stop")
    assert(handles[1].stops == 1 and handles[1].closes == 1, "waiting releases timer")

    state.sessions = {}
    task = status.start_task("50% %{1+1}")
    assert(refreshes == 1, "task transitions queue one lualine refresh")
    vim.wo.statusline = status.get_statusline()
    assert(render():find("50% %{1+1}", 1, true), "task labels remain literal in statusline expressions")
    assert(not status.get_status():find(spinner.expression, 1, true), "plain status API remains plain text")
    vim.wo.statusline = "another plugin"
    handles[2].tick(); drain()
    assert(handles[2].closes == 1, "hidden component releases timer")
    vim.wo.statusline = status.get_statusline()
    vim.o.laststatus = 0
    handles[3].tick(); drain()
    assert(handles[3].closes == 1, "hidden statusline releases timer")
    vim.o.laststatus = 3
    vim.wo.statusline = status.get_statusline()
    status.stop_task(task); task = nil
    assert(status.get_statusline() == "" and handles[4].closes == 1, "last task completion releases timer")
    rawset(vim.api, "nvim__redraw", nil)
    state.sessions.Codex = { pane_id = "fixture", provider_id = "Codex", agent_status = "thinking" }
    status.get_statusline()
    assert(#handles == 4, "older Neovim never falls back to a full redraw loop")
  end, debug.traceback)
  spinner.stop()
  if task then status.stop_task(task) end
  uv.new_timer, vim.schedule = previous.timer, previous.schedule
  rawset(vim.api, "nvim__redraw", previous.redraw)
  state.sessions, package.loaded.lualine = previous.sessions, previous.lualine
  vim.o.laststatus, vim.wo.statusline = previous.laststatus, previous.statusline
  assert(ok, err)
end

return M
