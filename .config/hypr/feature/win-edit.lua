local outputs = require("settings").outputs
local output_top = outputs.top
local output_bottom_left = outputs.bottom_left
local output_bottom_right = outputs.bottom_right

-- Preserve the Sway win-edit workflow as a Hyprland submap.
hl.bind("SUPER + E", hl.dsp.submap("win-edit"))
hl.define_submap("win-edit", function()
    hl.bind("SUPER + semicolon", hl.dsp.focus({ direction = "l" }))
    hl.bind("SUPER + slash", hl.dsp.focus({ direction = "d" }))
    hl.bind("SUPER + bracketleft", hl.dsp.focus({ direction = "u" }))
    hl.bind("SUPER + apostrophe", hl.dsp.focus({ direction = "r" }))

    hl.bind("SUPER + SHIFT + semicolon", hl.dsp.window.resize({ x = -5, y = 0, relative = true }), { repeating = true })
    hl.bind("SUPER + SHIFT + slash", hl.dsp.window.resize({ x = 0, y = 5, relative = true }), { repeating = true })
    hl.bind("SUPER + SHIFT + bracketleft", hl.dsp.window.resize({ x = 0, y = -5, relative = true }), { repeating = true })
    hl.bind("SUPER + SHIFT + apostrophe", hl.dsp.window.resize({ x = 5, y = 0, relative = true }), { repeating = true })

    hl.bind("SUPER + CTRL + semicolon", hl.dsp.window.move({ direction = "l" }))
    hl.bind("SUPER + CTRL + slash", hl.dsp.window.move({ direction = "d" }))
    hl.bind("SUPER + CTRL + bracketleft", hl.dsp.window.move({ direction = "u" }))
    hl.bind("SUPER + CTRL + apostrophe", hl.dsp.window.move({ direction = "r" }))

    hl.bind("SUPER + CTRL + L", hl.dsp.workspace.move({ monitor = "l" }))
    hl.bind("SUPER + CTRL + J", hl.dsp.workspace.move({ monitor = "d" }))
    hl.bind("SUPER + CTRL + K", hl.dsp.workspace.move({ monitor = "u" }))
    hl.bind("SUPER + CTRL + H", hl.dsp.workspace.move({ monitor = "r" }))

    for i = 1, 10 do
        local key = i % 10
        hl.bind("F" .. i, hl.dsp.focus({ workspace = i }))
        hl.bind("SUPER + SHIFT + " .. key, hl.dsp.window.move({ workspace = i }))
    end

    hl.bind("SUPER + CTRL + 1", hl.dsp.workspace.move({ monitor = output_top }))
    hl.bind("SUPER + CTRL + 2", hl.dsp.workspace.move({ monitor = output_bottom_left }))
    hl.bind("SUPER + CTRL + 3", hl.dsp.workspace.move({ monitor = output_bottom_right }))

    hl.bind("Return", hl.dsp.submap("reset"))
    hl.bind("Escape", hl.dsp.submap("reset"))
    hl.bind("CTRL + bracketleft", hl.dsp.submap("reset"))
    hl.bind("SUPER + E", hl.dsp.submap("reset"))
end)
