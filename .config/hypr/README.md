# Hyprland trial session

Hyprland is the normal desktop started through the official `start-hyprland`
watchdog by the login shell on local TTY1. It is
installed alongside Sway and uses the same physical three-display layout,
applications, Waybar style, and primary key bindings. It does not use a display
manager or a graphical session chooser.

## Start and stop

1. Log in on local TTY1; `~/.zshrc` executes `~/.config/hypr/start`.
2. To start it manually on another local TTY, run:

```sh
hyprland-start
```

Exit Hyprland with `Super+Shift+Escape`; the power menu includes an exit action.
`Super+Ctrl+Shift+Escape` exits immediately if the display is unusable.

Run `sway-start` from another local TTY when you want the established Sway
session. Never start either compositor from a terminal inside another graphical
session.

## Compatibility notes

- The config uses Hyprland 0.56's Lua format, not the deprecated hyprlang
  `hyprland.conf` syntax.
- The GTX 970 proprietary driver already has DRM modeset and fbdev enabled.
- The hardware KVM disconnects `DP-1`, `HDMI-A-1`, and its USB hub. Workspace
  placement rules are suspended while an output is absent and restored 1.5
  seconds after it returns. This preserves Sway-like migration/restoration and
  avoids stale native-Wayland Kitty surfaces during NVIDIA DRM modesetting.
- The Waybar configuration is separate from Sway's because workspace, submap,
  and focused-window modules use compositor-specific names.
- `rawhid-rust` uses Hyprland IPC for native applications and recognizes
  layer-shell Rofi by its `rofi` namespace, so Rofi can remain native Wayland.
- Screen sharing portals remain intentionally uninstalled, matching Sway.

After starting, inspect the detected outputs and input device names with:

```sh
hyprctl monitors all
hyprctl devices
hyprctl configerrors
```
