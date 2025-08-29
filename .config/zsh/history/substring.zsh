# --- グローバル変数 ---
typeset -g CUSTOM_HIST_INDEX
typeset -g CUSTOM_HIST_PREV_BUFFER
typeset -g CUSTOM_HIST_MATCHES

# --- 前方向 Ctrl+P ---
function custom-history-backward() {
  if [[ -n $BUFFER && $CUSTOM_HIST_PREV_BUFFER != $BUFFER ]]; then
    # TODO: オリジナル作る atuin search $BUFFER みたいな
    history-substring-search-up
  else
    if ! [[ -n $CUSTOM_HIST_MATCHES ]]; then
      local hist_all
      local is_gitdir=$(git rev-parse --is-inside-work-tree 2>/dev/null)
      if [[ $is_gitdir == 'true' ]]; then
        hist_all=("${(@f)$(atuin search --filter-mode workspace --cmd-only)}")
      else
        hist_all=("${(@f)$(atuin search --filter-mode directory --cmd-only)}")
      fi
      CUSTOM_HIST_MATCHES=("${hist_all[@]}")
    fi

    if ! [[ -n $BUFFER ]]; then
      CUSTOM_HIST_INDEX=
    fi

    if [[ ${#CUSTOM_HIST_MATCHES[@]} -eq 0 ]]; then return; fi
    if [[ -z $CUSTOM_HIST_INDEX ]]; then
      CUSTOM_HIST_INDEX=${#CUSTOM_HIST_MATCHES[@]}+1
    fi

    if (( CUSTOM_HIST_INDEX > 1 )); then
      (( CUSTOM_HIST_INDEX-- ))
      BUFFER=${CUSTOM_HIST_MATCHES[CUSTOM_HIST_INDEX]}
      CUSTOM_HIST_PREV_BUFFER=$BUFFER
      CURSOR=${#BUFFER}
    fi
  fi
}

# --- 後方向 Ctrl+N ---
function custom-history-forward() {
  if [[ -n $BUFFER && $CUSTOM_HIST_PREV_BUFFER != $BUFFER ]]; then
    history-substring-search-down
  else
    if [[ -z $CUSTOM_HIST_INDEX ]]; then return; fi

    if (( CUSTOM_HIST_INDEX < ${#CUSTOM_HIST_MATCHES[@]} )); then
      (( CUSTOM_HIST_INDEX++ ))
      BUFFER=${CUSTOM_HIST_MATCHES[CUSTOM_HIST_INDEX]}
      CUSTOM_HIST_PREV_BUFFER=$BUFFER
    else
      CUSTOM_HIST_INDEX=
    fi
    CURSOR=${#BUFFER}
  fi
}

function custom-precmd-reset-history() {
  CUSTOM_HIST_INDEX=
  CUSTOM_HIST_PREV_BUFFER=
  CUSTOM_HIST_MATCHES=()
}

autoload -Uz add-zsh-hook
add-zsh-hook precmd custom-precmd-reset-history

# --- ZLE widget登録 ---
zle -N custom-history-backward
zle -N custom-history-forward

# --- キーバインド ---
bindkey '^P' custom-history-backward
bindkey '^N' custom-history-forward
