# Disambiguate a standalone Escape from Alt+key in ZLE without KEYTIMEOUT.
#
# Legacy terminals encode Alt+n as the same bytes as Escape followed by n:
#   Alt+n  ==  ESC n  ==  1b 6e
# Kitty's keyboard protocol flag 1 instead reports Escape as CSI 27 u and
# Alt+n as CSI 110;3u.  tmux 3.7 understands modified CSI-u keys, but converts
# an unmodified Escape back to 0x1b, so tmux.conf bridges Escape only while an
# active ZLE pane is marked with @zle_csi_u.
#
# Set ZLE_CSI_U_DISABLE=1 before sourcing this file to disable the integration.

[[ ${ZLE_CSI_U_DISABLE:-0} == 1 ]] && return 0
[[ -n ${KITTY_WINDOW_ID:-} ]] || return 0

typeset -gi _ZLE_CSI_U_ACTIVE=0

__zle_csi_u_tty_write() {
  print -rn -- "$1" > /dev/tty 2>/dev/null
}

__zle_csi_u_tmux_mark() {
  [[ -n ${TMUX:-} && -n ${TMUX_PANE:-} ]] || return 0
  command tmux set-option -p -t "$TMUX_PANE" @zle_csi_u 1 2>/dev/null
}

__zle_csi_u_tmux_unmark() {
  [[ -n ${TMUX:-} && -n ${TMUX_PANE:-} ]] || return 0
  command tmux set-option -pu -t "$TMUX_PANE" @zle_csi_u 2>/dev/null
}

# Decode complete CSI-u keys back into ZLE's input queue. Resolving a widget
# here would freeze the binding before deferred plugins load, and give widgets
# the CSI-u sequence in $KEYS instead of the key they expect. String bindings
# let ZLE resolve the current (including local) keymap and preserve key macros.
__zle_csi_u_mirror_bindings() {
  local map binding widget letter upper legacy hex csi
  local -i index code
  local -a maps

  maps=(${(f)"$(bindkey -l)"})
  for map in $maps; do
    [[ $map == .* ]] && continue

    # Escape is deliberately a no-op.  It is now a complete key sequence, not
    # the prefix of a possible Alt binding, so the following key is independent.
    bindkey -M "$map" $'\e[27u' zle-csi-u-escape 2>/dev/null

    index=1
    for letter in {a..z}; do
      code=$(( 96 + index ))
      printf -v hex '%02x' $index
      printf -v legacy '%b' "\\x$hex"
      printf -v csi $'\e[%d;5u' $code
      bindkey -M "$map" -s "$csi" "$legacy" 2>/dev/null

      # In legacy mode Ctrl+C is handled by the tty driver as SIGINT, so its
      # ZLE binding is normally undefined.  CSI-u bypasses the tty signal path.
      if [[ $code == 99 ]]; then
        binding=$(bindkey -M "$map" "$legacy" 2>/dev/null)
        widget=${binding##* }
        if [[ $widget == undefined-key || $widget == self-insert ]]; then
          bindkey -M "$map" "$csi" send-break 2>/dev/null
        fi
      fi

      printf -v csi $'\e[%d;3u' $code
      bindkey -M "$map" -s "$csi" $'\e'"$letter" 2>/dev/null
      upper=${(U)letter}
      printf -v csi $'\e[%d;4u' $code
      bindkey -M "$map" -s "$csi" $'\e'"$upper" 2>/dev/null
      (( index++ ))
    done

    # Ctrl+Space is NUL in the legacy protocol and CSI 32;5u with flag 1.
    bindkey -M "$map" -s $'\e[32;5u' '^@' 2>/dev/null

    # tmux mode 2 emits BTab/Shift+Tab as CSI 9;2u rather than legacy CSI Z.
    bindkey -M "$map" -s $'\e[9;2u' $'\e[Z' 2>/dev/null
  done
}

__zle_csi_u_escape() {
  return 0
}
zle -N zle-csi-u-escape __zle_csi_u_escape
__zle_csi_u_mirror_bindings

__zle_csi_u_enable() {
  (( _ZLE_CSI_U_ACTIVE )) && return 0

  if [[ -n ${TMUX:-} ]]; then
    # tmux implements xterm modifyOtherKeys mode 2, not kitty's push/pop CSI-u
    # stack.  tmux translates modified keys to CSI-u according to tmux.conf.
    __zle_csi_u_tmux_mark
    __zle_csi_u_tty_write $'\e[>4;2m'
  else
    # Push kitty flag 1 (Disambiguate escape codes) on the main-screen stack.
    __zle_csi_u_tty_write $'\e[>1u'
  fi
  _ZLE_CSI_U_ACTIVE=1
}

__zle_csi_u_disable() {
  (( _ZLE_CSI_U_ACTIVE )) || return 0

  if [[ -n ${TMUX:-} ]]; then
    __zle_csi_u_tty_write $'\e[>4m'
    __zle_csi_u_tmux_unmark
  else
    # Pop exactly the mode pushed by __zle_csi_u_enable.
    __zle_csi_u_tty_write $'\e[<u'
  fi
  _ZLE_CSI_U_ACTIVE=0
}

# fzf 0.74.2 does not parse CSI-u letter keys in its light renderer.  fzf can
# run synchronously inside a ZLE widget, where line-finish has not fired, so
# temporarily restore the legacy keyboard mode around it.
if (( $+commands[fzf] )); then
  fzf() {
    local -i csi_u_was_active=$_ZLE_CSI_U_ACTIVE
    local -i csi_u_status
    (( csi_u_was_active )) && __zle_csi_u_disable
    {
      command fzf "$@"
      csi_u_status=$?
    } always {
      (( csi_u_was_active )) && __zle_csi_u_enable
    }
    return $csi_u_status
  }
fi

autoload -Uz add-zle-hook-widget add-zsh-hook
add-zle-hook-widget line-init __zle_csi_u_enable
add-zle-hook-widget line-finish __zle_csi_u_disable
add-zsh-hook preexec __zle_csi_u_disable
add-zsh-hook zshexit __zle_csi_u_disable
