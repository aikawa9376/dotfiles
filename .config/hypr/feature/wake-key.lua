-- Consume ordinary typing used to wake sleeping displays before the press
-- reaches the client/IME and starts its key repeat. Existing shortcuts win.
-- In 0.56.2 this event runs before keybind matching, idle activity and DPMS
-- wake. Lua event return values cannot cancel input, so use a catchall bind.
local wake_key
-- Catchall registration requires a named submap. Universal matching lets
-- this binding work without entering that submap or disturbing win-edit.
hl.define_submap("wake-key", function()
    wake_key = hl.bind("catchall", function() end, {
        ignore_mods = true,
        submap_universal = true,
        locked = true,
        dont_inhibit = true,
    })
end)
wake_key:set_enabled(false)

hl.on("input.keyboard.key", function(_, _, state)
    local asleep = false
    if state == 1 then
        local monitors = hl.get_monitors()
        asleep = #monitors > 0
        for _, monitor in ipairs(monitors) do
            if monitor.dpms_status then
                asleep = false
                break
            end
        end
    end
    -- Hyprland remembers that the press was consumed and suppresses its
    -- release too, even with this binding disabled before release matching.
    wake_key:set_enabled(asleep)
end)
