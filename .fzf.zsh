# Setup fzf
# ---------
if [[ ! "$PATH" == */home/aikawa/.fzf/bin* ]]; then
  export PATH="$PATH:/home/aikawa/.fzf/bin"
fi

# Auto-completion
# ---------------
[[ $- == *i* ]] && source "/home/aikawa/.fzf/shell/completion.zsh" 2> /dev/null

# Key bindings
# ------------
source "/home/aikawa/.fzf/shell/key-bindings.zsh"

