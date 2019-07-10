# -*- coding: utf-8 -*-

import re
from xkeysnail.transform import *

# [Global modemap] Change modifier keys as in xmodmap
# define_modmap({
#     Key.CAPSLOCK: Key.LEFT_CTRL
# })

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
    Key.LEFT_CTRL: [Key.ESC, Key.LEFT_CTRL],
    # Key.SPACE: [Key.SPACE, Key.LEFT_META],

    # Capslock is escape when pressed and released. Control when held down.
    # {Key.CAPSLOCK: [Key.ESC, Key.LEFT_CTRL]
    # To use this example, you can't remap capslock with define_modmap.
})

# Keybindings for Global
define_keymap(None, {
    # hhkb
    K("Super-h"): with_mark(K("kpasterisk")),
    K("Super-n"): with_mark(K("kpplus")),
    K("Super-m"): with_mark(K("kpminus")),
    K("Super-j"): with_mark(K("kpslash")),
    K("Shift-esc"): with_mark(K("Shift-grave")),
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
    K("Super-i"): with_mark(K("SYSRQ")),
    K("C-Super-h"): with_mark(K("left")),
    K("C-Super-j"): with_mark(K("down")),
    K("C-Super-k"): with_mark(K("up")),
    K("C-Super-l"): with_mark(K("right")),
    K("C-Super-n"): with_mark(K("C-down")),
    K("C-Super-p"): with_mark(K("C-up")),
    K("Super-Shift-h"): with_mark(K("Shift-left")),
    K("Super-Shift-j"): with_mark(K("Shift-down")),
    K("Super-Shift-k"): with_mark(K("Shift-up")),
    K("Super-Shift-l"): with_mark(K("Shift-right")),
}, "Global")

# Keybindings for Firefox/Chrome
define_keymap(re.compile("Firefox|Google-chrome"), {
    # Ctrl+Alt+j/k to switch next/previous tab
    K("C-j"): K("C-TAB"),
    K("C-k"): K("C-Shift-TAB"),
    K("Super-t"): with_mark(K("C-t")),
    K("Super-w"): with_mark(K("C-w")),
    K("Super-r"): with_mark(K("C-r")),
    K("C-Space"): K("C-f6"),
}, "Firefox and Chrome")

# Emacs-like keybindings in non-Emacs applications
define_keymap(lambda wm_class: wm_class not in ("Alacritty", "Rofi", "Kitty"), {
    # Cursor
    K("C-b"): with_mark(K("left")),
    K("C-f"): with_mark(K("right")),
    K("C-p"): with_mark(K("up")),
    K("C-n"): with_mark(K("down")),
    K("C-h"): with_mark(K("backspace")),
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
    # Beginning/End of line
    K("C-a"): with_mark(K("home")),
    K("C-e"): with_mark(K("end")),
    K("C-Shift-a"): with_mark(K("Shift-home")),
    K("C-Shift-e"): with_mark(K("Shift-end")),
    # Page up/down
    K("Super-l"): with_mark(K("page_up")),
    K("Super-dot"): with_mark(K("page_down")),
    K("Super-Shift-l"): with_mark(K("Shift-page_up")),
    K("Super-Shift-dot"): with_mark(K("Shift-page_down")),
    # Beginning/End of file
    K("Super-k"): with_mark(K("home")),
    K("Super-comma"): with_mark(K("end")),
    K("Super-Shift-k"): with_mark(K("Shift-home")),
    K("Super-Shift-comma"): with_mark(K("Shift-end")),
    # Newline
    K("Super-a"): [K("C-home"), K("C-a"), set_mark(True)],
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
    K("C-Shift-ro"): K("C-z"),
    # Mark
    # K("C-space"): set_mark(True),
    K("C-o"): with_or_set_mark(K("C-right")),
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