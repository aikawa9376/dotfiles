# Sway desktop session

Sway is the normal desktop started by the login shell on local TTY1. This does
not use a display manager or enable a system service. The old i3 configuration
remains available for an explicit `startx i3` from another TTY.

## Start and stop

1. Log in on local TTY1; `~/.zshrc` executes `~/.config/sway/start`.
2. To start it manually on another local TTY, run `sway-start`.
3. Exit Sway with `Super+Shift+Escape`.

Do not start Sway from a terminal inside i3. A compositor started there
uses a nested backend instead of taking control of the three physical outputs;
the launcher rejects that situation.

The launcher reuses the TTY login's user D-Bus rather than creating an isolated
one. This lets Sway applications use the same unlocked GNOME Keyring and Secret
Service as the normal login session.

If the screens are unusable, `Super+Ctrl+Shift+Escape` exits immediately
without a visible confirmation. If keyboard handling also fails, change to
another TTY, log in as the same user, and run `pkill -x sway`.

## Display layout

The output configuration mirrors the current X11 geometry:

```text
position (0,0)
+-----------------------+  DP-1: 3840x2160
|                       |
+-----------+-----------+
| DVI-I-1   | HDMI-A-1  |  both 1920x1080
+-----------+-----------+
position (0,2160)        position (1920,2160)
```

Physical Sway testing established the following connector mapping:

| Physical output | XRandR/i3 | Sway/DRM |
| --- | --- | --- |
| 4K upper display | `DP-0` | `DP-1` |
| FHD lower-left display | `DVI-I-1` | `DVI-I-1` |
| FHD lower-right display | `HDMI-0` | `HDMI-A-1` |

Workspaces 1, 2, and 3 are explicitly assigned to the upper, lower-left, and
lower-right outputs respectively. Output coordinates alone do not move an
existing workspace between connectors.

Once Sway starts, inspect what it actually detected with:

```sh
swaymsg -t get_outputs
```

## Input method

The launcher exports the fcitx GTK, Qt, XIM, and Kitty environment and Sway
starts `fcitx5` with the existing Mozc profile. Xwayland applications use the
same fcitx modules as under i3; native Wayland applications use Sway's input
method protocol or the toolkit module. Check native Vivaldi input and candidate
window placement in the physical session.

## Pointer

The Keyball39ish mouse interface uses libinput's adaptive acceleration with
`pointer_accel -0.3`. The setting targets only
`22871:512:aikawa_Keyball39ish_Mouse`, not every pointer device.

## Screenshots

`grim` and `slurp` provide native Wayland region screenshots, including the
backend used by LazyAgent. Screen sharing is intentionally not configured, so
the xdg-desktop-portal/PipeWire stack is not required for this setup.

## Deliberate compatibility limits

- The proprietary NVIDIA driver is unsupported by Sway upstream. The launcher
  passes Sway's required `--unsupported-gpu` acknowledgement only for this
  session.
- Xwayland remains enabled for applications that are not native Wayland yet.
- `polybar`, `xrandr`, `xdotool`, `xprop`, `xhost`, the i3 layout manager,
  and `xremap-x11` are not started because they are X11-specific.
- Waybar replaces Polybar in Sway and provides workspaces, focused-window
  title, system load, network/audio state, tray icons, and selected custom
  Polybar scripts. Like the X11 Polybar setup, it is shown only on the upper
  display (`DP-1`). This is restricted in both Sway's `bar` block and Waybar's
  own configuration. Its configuration lives in `~/.config/waybar/`.
- Sway runs the same Wayland-independent startup commands as i3 for
  `rawhid-rust`, Insync, `dhcpcd@enp5s0`, Docker, sshd, and one-shot chronyd
  synchronization. The services are started for the session, not enabled at
  boot.
- Sway refreshes the existing tmux server's Wayland, Sway IPC, D-Bus, toolkit,
  and input-method environment. Already running processes still need a restart
  if they were created under the previous display session.
- `Super+Space` switches between native Kitty and Vivaldi through Sway IPC.
- Ten minutes of inactivity powers off all displays without locking or
  suspending; input activity powers them back on while preserving workspaces.
- Waybar's power button opens suspend, reboot, poweroff, and Sway-exit actions.

If the compositor fails before showing the desktop, rerun it directly from the
TTY with debug logging and keep the output for diagnosis:

```sh
sway --unsupported-gpu --debug --config "$HOME/.config/sway/config" 2>"$HOME/sway-debug.log"
```

No NVIDIA workaround variables are enabled by default. They can hide the real
failure and should only be tried after checking the debug log.
