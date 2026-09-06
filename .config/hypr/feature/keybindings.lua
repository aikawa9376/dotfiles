local terminal = "kitty"
local launcher = "rofi -show drun -normal-window"
local switcher = "rofi -show combi -normal-window"

local function toggle_kitty_vivaldi()
    local active = hl.get_active_window()
    local target = active and active.class == "kitty" and "vivaldi-stable" or "kitty"
    local command = target == "kitty" and "kitty" or "vivaldi-stable"
    local windows = hl.get_windows({ class = "^" .. target .. "$" })

    if #windows > 0 then
        hl.dispatch(hl.dsp.focus({ window = windows[1] }))
    else
        hl.exec_cmd(command)
    end
end

-- Applications and focus.
hl.bind("SUPER + Return", hl.dsp.exec_cmd(terminal))
hl.bind("SUPER + Q", hl.dsp.window.close())
hl.bind("XF86AudioMute", hl.dsp.exec_cmd(switcher))
hl.bind("ALT + V", hl.dsp.exec_cmd(launcher))
hl.bind("CTRL + semicolon", hl.dsp.exec_cmd("copyq toggle"))
hl.bind("SUPER + Space", toggle_kitty_vivaldi)
-- Keyball emits KC_RGUI; keysym names are case-sensitive in Hyprland.
hl.bind("Super_R", hl.dsp.exec_cmd("fcitx5-remote -t"))
hl.bind("SUPER + semicolon", hl.dsp.focus({ direction = "l" }))
hl.bind("SUPER + slash", hl.dsp.focus({ direction = "d" }))
hl.bind("SUPER + bracketleft", hl.dsp.focus({ direction = "u" }))
hl.bind("SUPER + apostrophe", hl.dsp.focus({ direction = "r" }))

-- Layout. Hyprland groups are the closest equivalent to i3/Sway tabbed containers.
hl.bind("SUPER + SHIFT + H", hl.dsp.layout("preselect l"))
hl.bind("SUPER + SHIFT + V", hl.dsp.layout("preselect d"))
hl.bind("SUPER + SHIFT + Space", hl.dsp.window.fullscreen({ mode = "fullscreen" }))
hl.bind("SUPER + SHIFT + S", hl.dsp.group.toggle())
hl.bind("SUPER + SHIFT + W", hl.dsp.group.next())
hl.bind("SUPER + SHIFT + E", hl.dsp.layout("togglesplit"))
hl.bind("SUPER + SHIFT + F", hl.dsp.window.float())
hl.bind("SUPER + mouse:272", hl.dsp.window.drag(), { mouse = true })
hl.bind("SUPER + mouse:273", hl.dsp.window.resize(), { mouse = true })

hl.bind("ALT + Tab", hl.dsp.focus({ workspace = "e+1" }))
hl.bind("ALT + SHIFT + Tab", hl.dsp.focus({ workspace = "e-1" }))
hl.bind("SUPER + SHIFT + C", hl.dsp.exec_cmd("hyprctl reload"))
hl.bind("SUPER + Escape", hl.dsp.exec_cmd("hyprctl reload"))
