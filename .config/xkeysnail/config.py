# -*- coding: utf-8 -*-

import re
import subprocess

from xkeysnail.transform import *

# functions
def esc_hack():
    ime = subprocess.call('fcitx5-remote')
    if ime == 2:
        subprocess.call('fcitx5-remote -c')
    else:
        print('test')

# [Conditional modmap] Change modifier keys in certain applications
define_conditional_modmap(re.compile(r'Emacs'), {
    Key.RIGHT_CTRL: Key.ESC,
})

# [Multipurpose modmap] Give a key two meanings. A normal key when pressed and
# released, and a modifier key when held down with another key. See Xcape,
# Carabiner and caps2esc for ideas and concept.
define_multipurpose_modmap({
    # Enter is enter when pressed and released. Control when held down.
    Key.ENTER: [Key.ENTER, Key.RIGHT_CTRL],
    Key.TAB: [Key.TAB, Key.RIGHT_ALT],
    Key.RIGHT_SHIFT: [Key.MUTE, Key.RIGHT_SHIFT],
    Key.LEFT_SHIFT: [Key.RIGHT_META, Key.LEFT_SHIFT],
    Key.LEFT_CTRL: [Key.ESC, Key.LEFT_CTRL],

    # Capslock is escape when pressed and released. Control when held down.
    # {Key.CAPSLOCK: [Key.ESC, Key.LEFT_CTRL]
    # To use this example, you can't remap capslock with define_modmap.
})

define_conditional_multipurpose_modmap(lambda wm_class: wm_class in ("org.remmina.Remmina"), {
    # define_multipurpose_modmapで設定されたものがwm_classを上書きする
    Key.RIGHT_SHIFT: [Key.MUTE, Key.RIGHT_SHIFT],
})

# Keybindings for Global
define_keymap(None, {
    # hhkb
    K("Super-key_1"): with_mark(K("f1")),
    K("Super-key_2"): with_mark(K("f2")),
    K("Super-key_3"): with_mark(K("f3")),
    K("Super-key_4"): with_mark(K("f4")),
    K("Super-key_5"): with_mark(K("f5")),
    K("Super-key_6"): with_mark(K("f6")),
    K("Super-key_7"): with_mark(K("f7")),
    K("Super-key_8"): with_mark(K("f8")),
    K("Super-key_9"): with_mark(K("f9")),
    K("Super-key_0"): with_mark(K("f10")),
    K("Super-minus"): with_mark(K("f11")),
    K("Super-equal"): with_mark(K("f12")),
}, "Global")

define_keymap(lambda wm_class: wm_class not in ("org.remmina.Remmina|Rofi"), {
    # hhkb
    K("Super-h"): with_mark(K("kpasterisk")),
    K("Super-n"): with_mark(K("kpplus")),
    K("Super-m"): with_mark(K("kpminus")),
    K("Super-j"): with_mark(K("kpslash")),
    K("Super-i"): with_mark(K("SYSRQ")),
    K("Super-l"): with_mark(K("page_up")),
    K("Super-dot"): with_mark(K("page_down")),
    K("Super-Shift-l"): with_mark(K("Shift-page_up")),
    K("Super-Shift-dot"): with_mark(K("Shift-page_down")),
    K("Super-k"): with_mark(K("home")),
    K("Super-comma"): with_mark(K("end")),
    K("Super-Shift-k"): with_mark(K("Shift-home")),
    K("Super-Shift-comma"): with_mark(K("Shift-end")),
    K("LC-Mute"): with_mark(K("Alt-Shift-Super-z")),
    K("Shift-esc"): with_mark(K("Shift-grave")),
}, "Global-notwin")

# Keybindings for Rofi
define_keymap(re.compile("Rofi"), {
    K("Mute"): K("C-Tab"),
}, "Rofi")

# Keybindings for copyq
define_keymap(re.compile("copyq"), {
    K("C-m"): K("C-enter"),
}, "copyq")

# Keybindings for Alacritty/kitty
define_keymap(re.compile("Alacritty|kitty"), {
    K("RAlt-h"): with_mark(K("left")),
    K("RAlt-j"): with_mark(K("down")),
    K("RAlt-k"): with_mark(K("up")),
    K("RAlt-l"): with_mark(K("right")),
    K("RAlt-n"): with_mark(K("C-down")),
    K("RAlt-p"): with_mark(K("C-up")),
    K("RAlt-o"): with_mark(K("C-right")),
    K("RAlt-t"): with_mark(K("C-page_up")),
    K("RAlt-g"): with_mark(K("C-page_down")),
    K("RAlt-right_brace"): with_mark(K("RAlt-key_0")),
    K("RAlt-LSuper-o"): with_mark(K("C-left")),
    K("RAlt-LSuper-h"): with_mark(K("Shift-left")),
    K("RAlt-LSuper-j"): with_mark(K("Shift-down")),
    K("RAlt-LSuper-k"): with_mark(K("Shift-up")),
    K("RAlt-LSuper-l"): with_mark(K("Shift-right")),
}, "Alacritty and kitty")

# Keybindings for Firefox/Chrome
define_keymap(re.compile("Vivaldi-stable"), {
    K("RAlt-w"): K("C-w"),
    K("Super-t"): with_mark(K("C-t")),
    K("Super-Shift-t"): with_mark(K("C-Shift-t")),
    K("Super-w"): with_mark(K("C-w")),
    K("Super-Shift-r"): with_mark(K("C-Shift-r")),
    K("Super-Shift-v"): with_mark(K("C-Shift-v")),
}, "Vivaldi")

# Keybindings for Firefox/Chrome
define_keymap(re.compile("Firefox|Google-chrome"), {
    K("RAlt-l"): K("C-TAB"),
    K("RAlt-h"): K("C-Shift-TAB"),
    K("RAlt-j"): K("C-key_9"),
    K("RAlt-k"): K("C-key_1"),
    K("RAlt-w"): K("C-w"),
    K("Super-t"): with_mark(K("C-t")),
    K("Super-Shift-t"): with_mark(K("C-Shift-t")),
    K("Super-w"): with_mark(K("C-w")),
    K("Super-Shift-r"): with_mark(K("C-Shift-r")),
    K("Super-Shift-v"): with_mark(K("C-Shift-v")),
    K("C-Space"): K("f6"),
    K("C-g"): [K("f10"), K("f10"), set_mark(False)],
    K("C-o"): K("Alt-left"),
    K("C-j"): K("Alt-e"),
}, "Firefox and Chrome")

# Emacs-like keybindings in non-Emacs applications
define_keymap(lambda wm_class: wm_class not in
        ("Alacritty|Rofi|kitty|org.remmina.Remmina"), {
    # Cursor
    K("C-b"): with_mark(K("left")),
    K("C-f"): with_mark(K("right")),
    K("C-p"): with_mark(K("up")),
    K("C-n"): with_mark(K("down")),
    K("C-h"): with_mark(K("backspace")),
    K("C-w"): with_mark(K("C-backspace")),
    K("C-Shift-b"): with_mark(K("Shift-left")),
    K("C-Shift-f"): with_mark(K("Shift-right")),
    K("C-Shift-p"): with_mark(K("Shift-up")),
    K("C-Shift-n"): with_mark(K("Shift-down")),
    K("C-Shift-h"): with_mark(K("Shift-backspace")),
    K("C-i"): with_mark(K("tab")),
    K("C-Shift-i"): with_mark(K("Shift-tab")),
    # Forward/Backward word
    K("Super-b"): with_mark(K("C-left")),
    K("Super-f"): with_mark(K("C-right")),
    K("RAlt-b"): with_mark(K("C-left")),
    K("RAlt-f"): with_mark(K("C-right")),
    # Beginning/End of line
    K("C-a"): with_mark(K("home")),
    K("C-e"): with_mark(K("end")),
    K("C-Shift-a"): with_mark(K("Shift-home")),
    K("C-Shift-e"): with_mark(K("Shift-end")),
    # Newline
    K("Super-a"): [K("C-home"), K("C-a"), set_mark(False)],
    K("C-m"): K("enter"),
    # Copy
    K("Super-x"): [K("C-x"), set_mark(False)],
    K("Super-c"): [K("C-c"), set_mark(False)],
    K("Super-v"): [K("C-v"), set_mark(False)],
    # Delete
    K("C-d"): [K("delete"), set_mark(False)],
    K("Super-d"): [K("C-delete"), set_mark(False)],
    # Kill line
    K("C-k"): [K("Shift-end"), K("C-x"), set_mark(False)],
    K("C-u"): [K("Shift-home"), K("C-x"), set_mark(False)],
    # Undo
    K("Super-u"): [K("C-z"), set_mark(False)],
    K("Super-r"): [K("C-r"), set_mark(False)],
    K("C-Shift-ro"): K("C-z"),
    # Mark
    K("C-v"): set_mark(True),
    # K("C-v"): with_or_set_mark(K("C-right")),
    K("C-q"): escape_next_key,
    # Search
    # K("C-s"): K("F3"),
    # K("C-r"): K("Shift-F3"),
    # K("Super-Shift-key_5"): K("C-h"),
    # Cancel
    K("C-left_brace"): [K("esc"), set_mark(False)],
    # Right Click
    K("C-y"): with_mark(K("Shift-f10")),
}, "Emacs-like keys")
