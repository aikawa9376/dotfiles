local M = {}
function M.run()
  local Usage = require("lazyagent.acp.account_usage")
  local source = debug.getinfo(1, "S").source:gsub("^@", "")
  local fixture = vim.fn.fnamemodify(vim.fs.dirname(source) .. "/fake_usage.lua", ":p")
  local function probe(mode, extra)
    return Usage.new(vim.tbl_extend("force", { command = function()
      return { vim.v.progpath, "--headless", "--clean", "-u", "NONE", "-l", fixture, mode }
    end }, extra or {}))
  end
  local codex = probe("codex")
  local input = { provider = "Codex", cwd = "/tmp" }
  local entry = codex.get(input)
  assert(vim.wait(2000, function() return entry.status == "ready" end, 10), "Codex control probe completes")
  assert(#entry.windows == 2 and entry.windows[1].used == 25 and entry.windows[2].label == "Week", "account windows retain actual sizes")
  assert(entry.windows[1].resets_at:find("UTC", 1, true), "reset timestamp displayed")
  assert(codex.get(input) == entry and not entry.job, "cached reads do not start more processes")
  codex.close(); codex.close()
  local claude = probe("claude")
  entry = claude.get({ provider = "Claude", cwd = "/tmp" })
  assert(vim.wait(2000, function() return entry.status == "ready" end, 10), "Claude control probe completes")
  assert(entry.windows[3].label == "Week · Fable" and entry.windows[3].used == 4, "model-specific weekly allowance")
  assert(Usage.footer(entry) == "Session 56% left ↻11/20 10:00Z / Week 80% left", "compact footer uses unscoped limits")
  claude.close()
  local hanging = probe("hang", { timeout = 60 })
  entry = hanging.get(input)
  assert(vim.wait(1000, function() return entry.status == "usage request timed out" end, 10), "bounded timeout")
  assert(not entry.job and not entry.timer, "timeout releases job and timer")
  assert(hanging.get(input) == entry and not entry.job, "failed probes back off")
  hanging.close()
  local closing = probe("hang")
  local callback = false
  entry = closing.get(input, function() callback = true end)
  local job = entry.job
  closing.close()
  vim.wait(1000, function() return vim.fn.jobwait({ job }, 0)[1] ~= -1 end, 10)
  assert(not callback and not entry.job and not entry.timer, "closed UI cannot receive callbacks or leave probe handles")
  assert(closing.get(input).status == "unavailable", "closed owner cannot restart work")
  local parsed = Usage.parse("codex", { rateLimits = { primary = { usedPercent = 99 } }, rateLimitsByLimitId = {
    model = { limitName = "Model", secondary = { usedPercent = 0, windowDurationMins = 10080 } },
  } })
  assert(#parsed == 1 and parsed[1].used == 0 and parsed[1].label == "Week · Model", "bucket map takes precedence without duplicate legacy limits")
  assert(Usage.parse("claude", {}) == nil and Usage.parse("other", {}) == nil, "unknown data remains unavailable")
  parsed = Usage.parse("claude", { rate_limits = { limits = {
    { kind = "weekly_scoped", percent = 0, scope = { model = vim.NIL, surface = { display_name = "Code" } } },
  } } })
  assert(parsed[1].label == "Week · Code", "a null model scope does not hide the surface scope")
  assert(Usage.parse("claude", { rate_limits_available = true, rate_limits = vim.NIL }) == nil,
    "an available feature with no reported windows does not imply a full allowance")
  local mode = "codex"
  local retry = Usage.new({ refresh_interval = 0, timeout = 100, command = function()
    return { vim.v.progpath, "--headless", "--clean", "-u", "NONE", "-l", fixture, mode }
  end })
  entry = retry.get(input)
  assert(vim.wait(2000, function() return entry.status == "ready" end, 10), "initial limits before a failed refresh")
  mode = "hang"
  local windows = entry.windows
  retry.get(input, nil, true)
  assert(vim.wait(1000, function() return entry.status == "usage request timed out" end, 10), "failed refresh times out")
  assert(entry.windows == windows and entry.reported_at, "last good windows retain their report time on failure")
  retry.close()
end
return M
