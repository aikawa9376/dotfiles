# Hyprland trial session

Hyprland is the normal desktop started through the official `start-hyprland`
watchdog by the login shell on local TTY1. It is
installed alongside Sway and uses the same physical three-display layout,
applications, Waybar style, and primary key bindings. It does not use a display
manager or a graphical session chooser.

The launcher selects `hyprland.lua` through `HYPRLAND_CONFIG`. Passing the same
path with `start-hyprland -- --config` makes the 0.56.2 watchdog emit an
unconditional `WARN` about forwarding arguments. Early `DEBUG` initialization
messages may still appear and do not by themselves indicate a failure.

## Configuration layout

`hyprland.lua` is the entry point and explicitly loads `feature/` modules in
order. `settings.lua` holds shared output names; runtime state stays local to
the feature that owns it.

- `feature/monitors.lua`: output geometry, workspace placement, and KVM hotplug
  restoration, including placement handles and timers.
- `feature/desktop.lua`: application environment, appearance, layout defaults,
  animations, and input devices.
- `feature/keybindings.lua`: application launch/focus and ordinary window keys.
- `feature/win-edit.lua`: the window-editing submap.
- `feature/window-rules.lua`: application placement and floating dialogs.
- `feature/session.lua`: session autostart, delayed Fcitx startup, and exit keys.

Use Hyprland's `require("feature.name")` for new features. Keep a feature's
callbacks and their state together. Modules are resolved relative to the main
config, so no custom loader or `package.path` modification is needed.

Validate changes with:

```sh
Hyprland --verify-config --config ~/.config/hypr/hyprland.lua
```

## Start and stop

1. Log in on local TTY1; `~/.zshrc` executes `~/.config/hypr/start`.
2. To start it manually on another local TTY, run:

```sh
hyprland-start
```

Exit Hyprland with `Super+Shift+Escape`; the power menu includes an exit action.
`Super+Ctrl+Shift+Escape` exits immediately if the display is unusable.

Click the Waybar clock to open a compact monthly calendar below the bar.
Use the previous/current/next month buttons; click the clock again, press
Escape, or click outside to close it. The calendar runs inside Waybar as
`cffi/calendar`, with individual day labels and CSS for Sunday, Saturday,
and today. See `../waybar/modules/README.md` for build and maintenance.

The Waybar power icon uses its built-in GTK menu, defined in
`../waybar/power-menu.xml` and styled in `../waybar/style.css`. Its four
English actions retain their muted colors; click the icon again, click
outside, or press Escape to dismiss. The keyboard power-menu shortcut
continues to use `scripts/power-menu.sh` as a Rofi fallback.

Run `sway-start` from another local TTY when you want the established Sway
session. Never start either compositor from a terminal inside another graphical
session.

## Compatibility notes

- The config uses Hyprland 0.56's Lua format, not the deprecated hyprlang
  `hyprland.conf` syntax.
- The GTX 970 proprietary driver already has DRM modeset and fbdev enabled.
  These are startup prerequisites, not a guarantee of DPMS/hotplug recovery;
  see the local Aquamarine fix below.
- The hardware KVM disconnects `DP-1`, `HDMI-A-1`, and its USB hub. Workspace
  placement rules are suspended while an output is absent and restored 1.5
  seconds after it returns. This preserves Sway-like migration/restoration and
  avoids stale native-Wayland Kitty surfaces during NVIDIA DRM modesetting.
- The Waybar configuration is separate from Sway's because workspace, submap,
  and focused-window modules use compositor-specific names.
- `rawhid-rust` uses Hyprland IPC for native applications and recognizes
  layer-shell Rofi by its `rofi` namespace, so Rofi can remain native Wayland.
- Screen sharing portals remain intentionally uninstalled, matching Sway.

## Idle, suspend, and KVM wake-up

Automatic display power-off after 10 minutes is required and remains enabled.
The upper `DP-1` (workspace 1) and lower-right `HDMI-A-1` (workspace 3) switch
through the KVM; lower-left `DVI-I-1` (workspace 2) stays connected to this PC
and also sleeps during inactivity.

`scripts/idle.sh` wakes displays on activity and logind's system-resume event;
it does not request system suspend. Explicit suspend remains available in the
power menu. Hyprland also enables DPMS on input. The 1.5-second hotplug timer
restores workspace placement only, without an additional DPMS command.

Adding resume/input/hotplug wake commands did not resolve the freeze: a repeat
test returned images on outputs 1 and 3 but accepted no input, while output 2
stayed dark. That boot had no system suspend event, so actual system sleep is
not required to reproduce the symptom. Automatic DPMS combined with hotplug is
a suspect, not a proven root cause. Disabling automatic DPMS was rejected
because it sacrifices required behavior. Disabling display animations also
failed to fix the incident and has been reverted. NVIDIA memory preservation
and suspend/resume services were already enabled; USB keyboard/mouse
registration alone does not prove that Hyprland was processing input.

### Local Aquamarine CRTC fix

The captured repeat test showed responsive Hyprland IPC and incoming libinput
mouse events during the apparent freeze. DVI-I-1's sleeping CRTC 59 was released
and given to HDMI-A-1 on KVM return; DVI-I-1 moved to 79. Atomic modesets then
failed with `Invalid argument`, including DVI wake, despite IPC reporting DPMS
on. This identifies a display-configuration failure, rather than evidence of a
whole-compositor deadlock. The user confirmed a successful physical KVM/idle
return with the local CRTC-retention library loaded and its opt-in enabled.
This verifies the reported cycle, not every possible suspend/hotplug sequence.

`patches/aquamarine-0.15.0-preserve-crtc.patch` keeps a connected, sleeping
NVIDIA output's CRTC when `AQ_NVIDIA_PRESERVE_CRTC=1`. Disconnected outputs still
release their assignments. This is specific to the three-output GTX 970 setup
with four CRTCs; reserving sleeping outputs can limit hotplug on systems with
too few CRTCs. It preserves real DPMS power-off.

Build the isolated library with:

```sh
~/.config/hypr/scripts/build-aquamarine-kvm.sh
```

The script pins and checks the upstream source archive, applies the patch,
builds it and runs the non-graphical upstream tests. It stores the result under
the git-ignored `lib/` directory. `start` selects `lib/current` only while the
installed Hyprland, Aquamarine and linked runtime-library package versions
match the build stamp. After a package change it uses the system library until
the patch is rebuilt
or rebased. No system package is replaced. A session restart is required;
config reload cannot replace an already loaded library. For rollback, start
from a local TTY with `HYPRLAND_SYSTEM_AQUAMARINE=1 hyprland-start`.

If it happens again, try a keyboard connected directly to the PC or SSH from
another machine. From a terminal with this session's Hyprland environment, use:

```sh
timeout 5 hyprctl -j monitors all
timeout 5 hyprctl dispatch 'hl.dsp.dpms({ action = "enable" })'
journalctl -b -k --since '-10 min'
journalctl -b -u systemd-suspend.service -u nvidia-resume.service --since '-10 min'
```

SSH responding while Hyprland IPC times out points to a compositor stall;
responsive IPC with failed USB enumeration points toward the KVM/input path.
The idle helper must be restarted (or the session restarted) after editing it;
`hyprctl reload` alone does not restart autostart processes.

After starting, inspect the detected outputs and input device names with:

```sh
hyprctl monitors all
hyprctl devices
hyprctl configerrors
```
