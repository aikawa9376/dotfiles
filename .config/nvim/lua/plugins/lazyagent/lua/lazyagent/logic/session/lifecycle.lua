local M = {}

local state = require("lazyagent.logic.state")
local acp_logic = require("lazyagent.logic.acp")
local backend_logic = require("lazyagent.logic.backend")

local function call_watch(method, ...)
  local ok_watch, watch = pcall(require, "lazyagent.watch")
  if not ok_watch or not watch then
    return false
  end
  local fn = watch[method]
  if type(fn) ~= "function" then
    return false
  end
  return pcall(fn, ...)
end

local function send_interrupts_before_kill(agent_name, pane_id, backend_mod, sync)
  local backend_name = nil
  pcall(function()
    backend_name = (select(1, backend_logic.resolve_backend_for_agent(agent_name or "", nil)))
  end)
  local attempts = (state.opts and state.opts.interrupt_attempts) or 3
  local interval_ms = (state.opts and state.opts.interrupt_interval_ms) or 40
  if not pane_id or pane_id == "" then return end
  if not backend_mod or type(backend_mod.send_keys) ~= "function" then return end
  local key = "C-c"
  if backend_name == "builtin" then
    key = string.char(3)
  end
  for _ = 1, attempts do
    pcall(backend_mod.send_keys, pane_id, { key })
    pcall(vim.wait, interval_ms, function() return false end, 10, not sync)
  end
end

local function wait_for_pane_process_exit(agent_name, pane_id, backend_mod, timeout_ms, sync)
  timeout_ms = timeout_ms or ((state.opts and state.opts.post_interrupt_wait_ms) or 2000)
  local poll_interval = math.max(40, ((state.opts and state.opts.interrupt_interval_ms) or 40))
  local elapsed = 0
  if not pane_id or pane_id == "" then return false end

  local function pane_process_alive()
    if backend_mod and type(backend_mod.get_pane_pid) == "function" then
      local ok, pid = pcall(backend_mod.get_pane_pid, pane_id)
      if ok and pid and tonumber(pid) then
        local ok_stat, stat = pcall(vim.loop.fs_stat, "/proc/" .. tostring(pid))
        if ok_stat and stat then
          return true
        end
        return false
      end
    end
    if backend_mod and type(backend_mod.pane_exists) == "function" then
      local ok2, exists = pcall(backend_mod.pane_exists, pane_id)
      if not ok2 then return true end
      return exists == true
    end
    return true
  end

  if backend_mod and type(backend_mod.pane_exists) == "function" then
    local ok0, exists0 = pcall(backend_mod.pane_exists, pane_id)
    if not ok0 or not exists0 then return true end
  end

  while elapsed < timeout_ms do
    local alive = true
    local ok, res = pcall(pane_process_alive)
    if ok then alive = res else alive = true end
    if not alive then return true end
    pcall(vim.wait, poll_interval, function() return false end, 10, not sync)
    elapsed = elapsed + poll_interval
  end

  return false
end

function M.maybe_kill_pane(agent_name, pane_id, backend_mod, use_sync)
  local backend_name = nil
  pcall(function()
    backend_name = (select(1, backend_logic.resolve_backend_for_agent(agent_name or "", nil)))
  end)

  if acp_logic.is_acp_backend(backend_name) then
    pcall(send_interrupts_before_kill, agent_name, pane_id, backend_mod, use_sync)
    pcall(vim.wait, math.max(40, ((state.opts and state.opts.interrupt_interval_ms) or 40)), function() return false end, 10, not use_sync)
    if use_sync and backend_mod and type(backend_mod.kill_pane_sync) == "function" then
      backend_mod.kill_pane_sync(pane_id)
    elseif backend_mod and type(backend_mod.kill_pane) == "function" then
      backend_mod.kill_pane(pane_id)
    end
    return
  end

  pcall(send_interrupts_before_kill, agent_name, pane_id, backend_mod, use_sync)
  local ok_wait, exited = pcall(
    wait_for_pane_process_exit,
    agent_name,
    pane_id,
    backend_mod,
    (state.opts and state.opts.post_interrupt_wait_ms) or 2000,
    use_sync
  )
  if not ok_wait or not exited then
    if use_sync and backend_mod and type(backend_mod.kill_pane_sync) == "function" then
      backend_mod.kill_pane_sync(pane_id)
    elseif backend_mod and type(backend_mod.kill_pane) == "function" then
      backend_mod.kill_pane(pane_id)
    end
  end
end

function M.wait_for_idle_before_close(agent_name, on_ready)
  local s = state.sessions[agent_name]
  if not s then
    on_ready()
    return
  end

  local backend_name, backend_mod = backend_logic.resolve_backend_for_agent(agent_name, nil)
  if acp_logic.is_acp_backend(backend_name) then
    on_ready()
    return
  end

  if backend_mod and type(backend_mod.pane_exists) == "function" then
    local ok, exists = pcall(backend_mod.pane_exists, s.pane_id)
    if ok and not exists then
      on_ready()
      return
    end
  end

  if s.agent_status ~= "thinking" then
    on_ready()
    return
  end

  local timeout = 5000
  local timer = vim.loop.new_timer()
  local done = false

  local function finish()
    if done then return end
    done = true
    if timer then
      pcall(function() timer:stop(); timer:close() end)
    end
    s.on_idle_callback = nil
    on_ready()
  end

  s.on_idle_callback = finish
  timer:start(timeout, 0, vim.schedule_wrap(finish))
end

function M.maybe_disable_watchers()
  local cnt = 0
  for _, s in pairs(state.sessions or {}) do
    if s and s.pane_id and s.pane_id ~= "" then
      local should_watch = s.watch_enabled
      if should_watch == nil then should_watch = true end
      if should_watch then
        cnt = cnt + 1
      end
    end
  end
  if cnt == 0 then
    call_watch("disable")
    call_watch("stop_follow")
  end
end

return M
