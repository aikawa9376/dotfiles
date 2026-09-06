# Unambiguous Escape and Alt keys in ZLE

Legacy terminal input cannot distinguish `Alt+n` from an `Escape` byte
immediately followed by `n`; both are `1b 6e`.  `KEYTIMEOUT` only guesses from
timing and therefore cannot remove this ambiguity.

While ZLE is active, `zsh-csi-u.zsh` enables kitty keyboard protocol flag 1
(`Disambiguate escape codes`).  Outside tmux it pushes the mode with
`CSI > 1 u` and pops it with `CSI < u`.  Kitty then sends:

- Escape: `CSI 27 u` (`1b 5b 32 37 75`)
- Alt+n: `CSI 110;3u` (`1b 5b 31 31 30 3b 33 75`)
- Alt+f: `CSI 102;3u`
- Ctrl+C: `CSI 99;5u`

Enter (`0d`), Backspace (`7f`), unmodified arrows, and unmodified function keys
keep their legacy encodings with flag 1.

## tmux

tmux 3.7b does not implement kitty's keyboard-mode stack for applications.
It accepts xterm's `CSI > 4;2 m` request and translates modified keys to CSI-u
when `extended-keys-format csi-u` is set.  It still converts unmodified Escape
to bare `1b`, so `tmux.conf` has a narrow bridge: only a zsh pane marked
`@zle_csi_u=1` and currently running zsh receives Escape as `CSI 27 u`.
Neovim and other applications are unaffected and negotiate their own modes.
`.zshrc` therefore leaves `TERM` untouched: kitty supplies `xterm-kitty`
directly, while tmux supplies `tmux-256color` to its panes.

CSI-u Ctrl and Alt keys are decoded with `bindkey -s` in every existing ZLE
keymap. Once the complete sequence arrives, ZLE looks up the corresponding
legacy key in the current keymap. The terminal still uses extended keys;
this conversion happens only inside ZLE. Escape remains its own complete
sequence, so Escape followed by a letter does not turn into Alt+letter.

This follows bindings changed by deferred plugins (including autopair and
fzf-tab), preserves string macros, and gives widgets the expected legacy
`KEYS` value. Previously, the integration copied widget names once at startup,
which missed later changes and bypassed key macros. Ordinary binding changes
no longer require a refresh. Run `__zle_csi_u_mirror_bindings` after creating
a new keymap that does not inherit the decoding bindings. Ctrl+C retains a
`send-break` fallback in maps where its legacy binding was undefined or
`self-insert` at installation time.

The installed fzf 0.74.2 parser does not handle CSI-u letter keys, so the
`fzf` shell wrapper temporarily suspends the mode when fzf is run inside a
ZLE widget.

## Troubleshooting

Reload tmux after changing the config, then start a new zsh:

```console
tmux source-file ~/.config/tmux/tmux.conf
exec zsh
```

Check tmux's effective settings:

```console
tmux show-options -gs extended-keys
tmux show-options -gs extended-keys-format
tmux display-message -p '#{client_termfeatures} / #{pane_key_mode}'
```

The first two should show `on` and `csi-u`; client features should include
`extkeys`.  `pane_key_mode` is `Ext 2` while ZLE requests it.

## Disable

Set this before `zsh-csi-u.zsh` is sourced:

```zsh
export ZLE_CSI_U_DISABLE=1
```

Then reload tmux after commenting out the `extended-keys` block and the
`bind-key -n Escape` bridge in `tmux.conf`.
