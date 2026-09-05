-- Hyprland 0.56+ Lua configuration. TTY1 starts it automatically through
-- ~/.zshrc; `hyprland-start` remains available on another local TTY.

local terminal = "kitty"
local launcher = "rofi -show drun -normal-window"
local switcher = "rofi -show combi -normal-window"

local output_top = "DP-1"
local output_bottom_left = "DVI-I-1"
local output_bottom_right = "HDMI-A-1"
local fcitx_start_timer

-- Match the physical layout already verified under Sway.
hl.monitor({ output = output_top, mode = "3840x2160", position = "0x0", scale = 1 })
hl.monitor({ output = output_bottom_left, mode = "1920x1080", position = "0x2160", scale = 1 })
hl.monitor({ output = output_bottom_right, mode = "1920x1080", position = "1920x2160", scale = 1 })
hl.monitor({ output = "", mode = "preferred", position = "auto-right", scale = 1 })

-- NVIDIA and native-Wayland application environment.
hl.env("LIBVA_DRIVER_NAME", "nvidia")
hl.env("__GLX_VENDOR_LIBRARY_NAME", "nvidia")
hl.env("ELECTRON_OZONE_PLATFORM_HINT", "auto")

hl.config({
    general = {
        -- Adjacent windows add their facing edges, so split 15 px as 7 + 8.
        gaps_in = { top = 7, right = 8, bottom = 8, left = 7 },
        gaps_out = 15,
        border_size = 1,
        col = {
            active_border = "rgba(00ced1ff)",
            inactive_border = "rgba(000000ff)",
        },
        layout = "dwindle",
        resize_on_border = true,
    },
    decoration = {
        rounding = 0,
        rounding_power = 2,
        shadow = {
            enabled = true,
            range = 10,
            render_power = 3,
            color = 0x66000000,
        },
        blur = {
            enabled = true,
            size = 5,
            passes = 2,
        },
    },
    animations = {
        enabled = true,
    },
    input = {
        repeat_delay = 150,
        repeat_rate = 230,
        follow_mouse = 1,
    },
    dwindle = {
        preserve_split = true,
    },
    xwayland = {
        enabled = true,
    },
    misc = {
        disable_hyprland_logo = true,
        disable_splash_rendering = true,
        force_default_wallpaper = 0,
    },
})

hl.curve("desktop", { type = "bezier", points = { { 0.22, 1 }, { 0.36, 1 } } })
hl.animation({ leaf = "windows", enabled = true, speed = 4.5, bezier = "desktop" })
hl.animation({ leaf = "fade", enabled = true, speed = 3.0, bezier = "desktop" })
hl.animation({ leaf = "workspaces", enabled = true, speed = 4.0, bezier = "desktop", style = "slide" })

-- Hyprland normalizes libinput names to lower-case, dash-separated identifiers.
hl.device({
    name = "aikawa-keyball39ish-mouse",
    accel_profile = "adaptive",
    sensitivity = -0.3,
})

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

-- Window placement and floating dialogs.
hl.window_rule({ name = "alacritty-workspace", match = { class = "[Aa]lacritty" }, workspace = "2" })
hl.window_rule({ name = "luakit-workspace", match = { class = "[Ll]uakit" }, workspace = "2" })
hl.window_rule({ name = "remmina-workspace", match = { class = "org.remmina.Remmina|Remmina" }, workspace = "3" })

hl.window_rule({ name = "insync-float", match = { class = "[Ii]nsync" }, float = true, center = true, size = { 640, 450 } })
hl.window_rule({ name = "copyq-float", match = { class = "([Cc]opyq|com\\.github\\.hluk\\.copyq)" }, float = true, center = true, size = { 725, 837 } })
hl.window_rule({ name = "feh-float", match = { class = "[Ff]eh" }, float = true, center = true, size = { 600, 400 } })
hl.window_rule({ name = "ssr-float", match = { class = "SimpleScreenRecorder" }, float = true, center = true, size = { 600, 400 } })
hl.window_rule({ name = "rofi-float", match = { class = "[Rr]ofi" }, float = true, center = true })
hl.window_rule({ name = "fcitx-config-float", match = { class = "fcitx5-config-qt" }, float = true, center = true, size = { 600, 400 } })
hl.window_rule({ name = "network-config-float", match = { class = "nm-connection-editor" }, float = true, center = true, size = { 800, 600 } })
hl.window_rule({ name = "mozc-tool-float", match = { class = "mozc_tool" }, float = true, center = true, size = { 600, 400 } })
hl.window_rule({ name = "modal-float", match = { modal = true }, float = true, center = true })

hl.on("hyprland.start", function()
    hl.exec_cmd('dbus-update-activation-environment --systemd DISPLAY WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP XDG_SESSION_TYPE GTK_IM_MODULE QT_IM_MODULE XMODIFIERS GLFW_IM_MODULE GDK_BACKEND QT_QPA_PLATFORM MOZ_ENABLE_WAYLAND ELECTRON_OZONE_PLATFORM_HINT')
    hl.exec_cmd('$HOME/.config/sway/scripts/update-tmux-environment.sh')
    hl.exec_cmd('waybar -c "$HOME/.config/waybar/hyprland.jsonc" -s "$HOME/.config/waybar/style.css"')
    -- Let Hyprland finish setting up its seat before Fcitx attaches to it.
    fcitx_start_timer = hl.timer(function()
        hl.exec_cmd("fcitx5 -d -r")
    end, { timeout = 1500, type = "oneshot" })
    hl.exec_cmd("copyq")
    hl.exec_cmd("$HOME/.config/sway/scripts/configure-copyq-wayland.sh")
    hl.exec_cmd("insync start")
    hl.exec_cmd("sudo rawhid-rust")
    hl.exec_cmd("$HOME/.config/hypr/scripts/idle.sh")
    hl.exec_cmd("sudo systemctl start dhcpcd@enp5s0.service")
    hl.exec_cmd("sudo systemctl start docker")
    hl.exec_cmd("sudo systemctl start sshd")
    hl.exec_cmd("sudo chronyd -q 'pool pool.ntp.org iburst'")
end)

hl.bind("SUPER + SHIFT + Escape", hl.dsp.exec_cmd("$HOME/.config/hypr/scripts/power-menu.sh"))
hl.bind("SUPER + CTRL + SHIFT + Escape", hl.dsp.exit())
