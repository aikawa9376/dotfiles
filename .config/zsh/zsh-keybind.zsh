# Merge emacs mode to viins mode
bindkey -r '^['
bindkey '\er' history-incremental-pattern-search-forward
bindkey '^?'  backward-delete-char
bindkey '^A'  beginning-of-line
bindkey '^B'  backward-char
bindkey '^D'  delete-char-or-list
bindkey '^E'  end-of-line
bindkey '^F'  forward-char
# bindkey -M viins '^G'  send-break
bindkey '^H'  backward-delete-char
bindkey '^K'  kill-line
# bindkey -M viins '^R'  history-incremental-pattern-search-backward
bindkey '^U'  backward-kill-line
bindkey '^W'  backward-kill-word
bindkey '^Y'  yank
