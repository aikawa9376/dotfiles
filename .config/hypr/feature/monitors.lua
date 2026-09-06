local outputs = require("settings").outputs
local output_top = outputs.top
local output_bottom_left = outputs.bottom_left
local output_bottom_right = outputs.bottom_right

-- Match the physical layout already verified under Sway.
hl.monitor({ output = output_top, mode = "3840x2160", position = "0x0", scale = 1 })
hl.monitor({ output = output_bottom_left, mode = "1920x1080", position = "0x2160", scale = 1 })
hl.monitor({ output = output_bottom_right, mode = "1920x1080", position = "1920x2160", scale = 1 })
hl.monitor({ output = "", mode = "preferred", position = "auto-right", scale = 1 })

-- Keep the three main workspaces alive independently of their current output.
-- A KVM switch disconnects DP-1 and HDMI-A-1. Temporarily suspend the affected
-- placement rule while Hyprland migrates its workspace to a surviving output,
-- then restore it after the reconnected output has finished modesetting.
for workspace = 1, 3 do
    hl.workspace_rule({ workspace = tostring(workspace), persistent = true })
end

local workspace_placement_rules = {
    [output_top] = hl.workspace_rule({ workspace = "1", monitor = output_top, default = true }),
    [output_bottom_left] = hl.workspace_rule({ workspace = "2", monitor = output_bottom_left, default = true }),
    [output_bottom_right] = hl.workspace_rule({ workspace = "3", monitor = output_bottom_right, default = true }),
}
local workspace_restore_timers = {}

hl.on("monitor.removed", function(monitor)
    local placement_rule = workspace_placement_rules[monitor.name]
    if placement_rule then
        local restore_timer = workspace_restore_timers[monitor.name]
        if restore_timer then
            restore_timer:set_enabled(false)
            workspace_restore_timers[monitor.name] = nil
        end
        placement_rule:set_enabled(false)
    end
end)

hl.on("monitor.added", function(monitor)
    local placement_rule = workspace_placement_rules[monitor.name]
    if not placement_rule then
        return
    end

    local restore_timer = workspace_restore_timers[monitor.name]
    if restore_timer then
        restore_timer:set_enabled(false)
    end

    workspace_restore_timers[monitor.name] = hl.timer(function()
        placement_rule:set_enabled(true)
        workspace_restore_timers[monitor.name] = nil
    end, { timeout = 1500, type = "oneshot" })
end)
