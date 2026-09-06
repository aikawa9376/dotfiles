-- Hyprland 0.56+ Lua configuration. TTY1 starts it automatically through
-- ~/.zshrc; `hyprland-start` remains available on another local TTY.

-- Keep feature loading explicit so registration order is visible here.
-- Hyprland resolves these modules relative to this configuration file.
require("feature.monitors")
require("feature.desktop")
require("feature.keybindings")
require("feature.win-edit")
require("feature.window-rules")
require("feature.session")
