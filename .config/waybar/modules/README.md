# Waybar calendar

`calendar.c` is a Waybar CFFI ABI 2 module. It owns the clock label, one GTK
menu anchored below the clock, a grid of day labels, and month navigation.
It runs inside Waybar; no Rofi, external calendar process, or polling IPC is
involved. Click the clock again, click outside, or press Escape to dismiss.
Each opening starts at the current month. Sunday starts the week.

Style it through `../style.css`: `#calendar-popup`, `.calendar-content`,
`.day`, `.weekday`, `.sunday`, `.saturday`, and `.today`. The content has
15px padding; the popup is approximately 330px wide. Date cells are labels,
not the monolithic GTK Calendar widget.

`../start-hyprland.sh` builds the module when needed and starts Waybar using
`../hyprland.jsonc`. Building requires `cc`, `pkg-config`, and GTK 3 development
files (provided here by gcc, pkgconf, and gtk3). The generated `calendar.so`
is ignored by Git. `module_path` in the Waybar config is an absolute path;
Waybar passes it directly to `dlopen` without expanding `~` or `$HOME`.

```sh
sh ~/.config/waybar/modules/build-calendar.sh
```

After changing the C source, rebuild and restart the Hyprland Waybar process
through `start-hyprland.sh`. A configuration reload may retain an already
loaded shared library. CSS changes only need a normal Waybar reload.
When switching from the built-in clock to this module, restart the bar as
well: the live process in this setup retained the old module configuration
after SIGUSR2. Confirm `calendar.so` appears in `/proc/<waybar-pid>/maps`,
then verify the actual production clock, not only a temporary test bar.

GTK menus handle the compositor popup grab so a click outside dismisses the
menu. The custom item keeps navigation available; `menu_click` routes clicks
inside the menu before GTK can activate/dismiss the containing menu item.
The anchor rectangle is local to Waybar's event-box GdkWindow, preventing
double application of the module's horizontal allocation offset.
`wbcffi_deinit` removes the clock timer and destroys the menu on bar teardown.

Run the GTK widget tests from this directory in a graphical session:

```sh
cc -std=c11 -Wall -Wextra -Werror test-calendar.c -o /tmp/test-waybar-calendar $(pkg-config --cflags --libs gtk+-3.0)
/tmp/test-waybar-calendar
```

They cover leap day alignment, month/year boundaries, five/six-row months,
weekend/today CSS classes, and cleanup. Real Wayland pointer events were also
used with a temporary Waybar to verify opening, next month, and repeat-clock
click dismissal. Popup geometry and input must be checked on connected
outputs; helper-process tests alone do not establish click behavior.

CFFI ABI reference:
https://github.com/Alexays/Waybar/blob/master/resources/custom_modules/cffi_example/waybar_cffi_module.h
