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
