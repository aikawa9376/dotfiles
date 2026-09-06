local fcitx_start_timer

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
