local outputs = require("settings").outputs
local M = {}

function M.sleep()
    local connected = {}
    for _, monitor in ipairs(hl.get_monitors()) do
        connected[monitor.name] = true
    end
    for _, name in pairs(outputs) do
        if not connected[name] then
            return
        end
    end
    hl.dispatch(hl.dsp.dpms({ action = "disable" }))
end

-- If the KVM leaves after idle sleep, wake the surviving outputs as well.
hl.on("monitor.removed", function()
    for _, monitor in ipairs(hl.get_monitors()) do
        if not monitor.dpms_status then
            hl.dispatch(hl.dsp.dpms({ action = "enable" }))
            return
        end
    end
end)

return M
