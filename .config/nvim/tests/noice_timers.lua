local source = debug.getinfo(1, "S").source:gsub("^@", "")
vim.opt.rtp:prepend(vim.fs.dirname(vim.fs.dirname(source)))
vim.opt.rtp:append(assert(vim.env.NOICE_RTP))
vim.opt.rtp:append(assert(vim.env.NUI_RTP))
local function count()
  local n = 0
  vim.uv.walk(function(h)
    if tostring(h):find("uv_timer_t", 1, true) and not h:is_closing() then n = n + 1 end
  end)
  return n
end
local Mini = require("noice.view.backend.mini")
local patch = require("plugins.noice_util").patch_mini_timers
patch()
local autohide = Mini.autohide
patch()
assert(Mini.autohide == autohide, "the mini timer patch is installed once")
local updates, keep = 0, false
local view = setmetatable({
  timers = {}, active = {}, _opts = { timeout = 1 },
  can_hide = function() return not keep end,
  update = function() updates = updates + 1 end,
  clear = function() end,
}, { __index = Mini })
local before = count()
for i = 1, 1000 do view.active[i] = {}; view:autohide(i) end
assert(vim.wait(1000, function() return updates == 1000 end))
assert(not next(view.active) and not next(view.timers), "expired messages release their timers")
keep = true
view.active[1001] = {}; view:autohide(1001)
vim.wait(20, function() return false end)
assert(view.timers[1001] and view.active[1001], "kept messages retain their running timeout")
keep = false
assert(vim.wait(1000, function() return not view.active[1001] end))
view.active[1002] = {}; view:autohide(1002)
view.active[1003] = {}; view:autohide(1003)
view.active[1003] = nil -- removal before timeout must also release its handle
assert(vim.wait(1000, function() return not next(view.timers) end))
view.active[1004] = {}; view:autohide(1004)
view:dismiss()
assert(not next(view.active) and not next(view.timers), "dismiss cancels pending timeouts")
vim.wait(20, function() return false end)
assert(count() == before, "mini notifications leave no libuv timers behind")
print("Noice mini timer lifecycle passed (1,000 expirations, keep, removal, dismiss)")
