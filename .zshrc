# -------------------------------------
# zinit
# -------------------------------------
### Added by Zinit's installer
if [[ ! -f $HOME/.zinit/bin/zinit.zsh ]]; then
    print -P "%F{33}▓▒░ %F{220}Installing DHARMA Initiative Plugin Manager (zdharma/zinit)…%f"
    command mkdir -p $HOME/.zinit
    command git clone https://github.com/zdharma/zinit $HOME/.zinit/bin && \
        print -P "%F{33}▓▒░ %F{34}Installation successful.%F" || \
        print -P "%F{160}▓▒░ The clone has failed.%F"
fi
source ~/.zinit/bin/zinit.zsh
autoload -Uz _zinit
(( ${+_comps} )) && _comps[zinit]=_zinit

# zsh-completions
zinit ice wait'!0' lucid; zinit load "zsh-users/zsh-completions"
# zsh-history-substring-search
zinit ice wait'!0' lucid; zinit load "zsh-users/zsh-history-substring-search"
# zsh-syntax-highlighting
zinit ice wait'!0' lucid atinit"zpcompinit; zpcdreplay"
zinit load "zdharma/fast-syntax-highlighting"
# autosuggestions
zinit ice wait'!0' lucid; zinit load "zsh-users/zsh-autosuggestions"
# ゴミ箱機能
zinit ice wait'!0' lucid; zinit load "aikawa9376/zsh-gomi"
# pair auto
zinit ice wait'!0' lucid; zinit load "hlissner/zsh-autopair"
# enhancd
zinit ice lucid wait'!0' atclone'rm -rf functions'
zinit load "b4b4r07/enhancd"
# tmux fzf
zinit ice lucid as"program" pick"tmuximum"
zinit light "arks22/tmuximum"
# history
zinit ice lucid as'program' multisrc'misc/zsh/{history,keybind}.zsh' make'install'
zinit light "b4b4r07/history"
# abbr
zinit ice lucid
zinit light "momo-lab/zsh-abbrev-alias"
# fzf-tab
zinit ice wait'!0' lucid; zinit load "Aloxaf/fzf-tab"
# fasd
zinit ice lucid if'[[ -n "$commands[fasd]" ]]'
zinit snippet OMZ::plugins/fasd/fasd.plugin.zsh
# git plugin
zinit ice lucid
zinit snippet OMZ::plugins/git/git.plugin.zsh
# ls_colors plugin
zinit ice atclone"dircolors -b LS_COLORS > clrs.zsh" \
    atpull'%atclone' pick"clrs.zsh" nocompile'!' \
    atload'export LS_COLORS=$(sed -E '\''s/;1:/:/g;s/(:di=[^:]*)/\1;1/'\'' <<<"$LS_COLORS"); \
      zstyle ":completion:*" list-colors ${(s.:.)LS_COLORS}'
zinit light trapd00r/LS_COLORS

# -------------------------------------
# 基本設定
# -------------------------------------
export PATH="/usr/local/bin:$PATH"
export TERM='xterm-256color'
export XAPIAN_CJK_NGRAM=1
export EDITOR='nvim'
export PAGER='bat'
export WCWIDTH_CJK_LEGACY='yes'
export ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE="fg=cyan"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_CACHE_HOME="$HOME/.cache"
export BAT_CONFIG_PATH="$XDG_CONFIG_HOME/bat/conf"
export RIPGREP_CONFIG_PATH="$XDG_CONFIG_HOME/rg/conf"

# go lang
export GOPATH="$HOME/go"
export PATH="$GOPATH/bin:$PATH"

# rust lang
export RUSTPATH="$HOME/.cargo"
export PATH="$RUSTPATH/bin:$PATH"

# local settings
case ${OSTYPE} in
  linux*)
    # homebrew
    export BREWPATH="/home/linuxbrew/.linuxbrew/bin"
    export PATH="$BREWPATH:$PATH"
esac

stty stop undef
stty start undef
setopt no_flow_control
# KEYTIMEOUT=1
case $(uname -a) in
   *Microsoft*) unsetopt BG_NICE ;;
esac

# 外部ファイル読み込み
export ZCONFDIR="$HOME/.config/zsh"
function loadlib() {
  lib=${1:?"You have to specify a library file"}
  if [ -f "$lib" ];then #ファイルの存在を確認
    source "$lib"
  fi
}
loadlib $ZCONFDIR/zsh-vimode.zsh
[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh
loadlib $ZCONFDIR/zsh-vcs.zsh
loadlib $ZCONFDIR/zsh-alias.zsh
loadlib $ZCONFDIR/zsh-functions.zsh
loadlib $ZCONFDIR/zsh-bookmark.zsh
loadlib $ZCONFDIR/zsh-docker.zsh
loadlib $ZCONFDIR/history/substring.zsh

# -------------------------------------
# fzf
# -------------------------------------
export FZF_DEFAULT_COMMAND='(fd --type file --follow --hidden --color=always --exclude .git) 2> /dev/null'
export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
export FZF_CTRL_T_OPTS="--ansi $FZF_DEFAULT_PREVIEW"
export FZF_CTRL_R_OPTS='--preview-window hidden --tiebreak index -s'
export FZF_ALT_C_COMMAND='fd --type directory --follow --hidden --color=always --exclude .git'
export FZF_ALT_C_OPTS="--ansi --preview 'tree -C {} | head -200'"
export FZF_DEFAULT_PREVIEW='--preview "
  [[ -d {} ]]  &&
  tree -C {}
  [[ -f {} && $(file --mime {}) =~ (png|jpg|gif|ttf) && $(file --mime {}) =~ (^binary) ]] &&
  echo {} is a binary file
  (bat --style=changes --color=always {} ||
   cat {}) 2> /dev/null | head -500"'
export FZF_COMPLETION_TRIGGER=''
export FZF_DEFAULT_OPTS='
--height 40%
--reverse
--extended
--cycle
--no-hscroll
--inline-info
--tabstop=2
--preview-window noborder
--history '$HOME'/.fzf/history
--bind alt-k:preview-up,alt-j:preview-down,ctrl-n:down,ctrl-p:up
--bind alt-a:toggle-all,home:top
--bind alt-p:previous-history,alt-n:next-history,ctrl-k:kill-line
--bind "alt-i:execute(feh {})"
--color dark,hl:34,hl+:40,bg+:235,fg+:15
--color info:108,prompt:109,spinner:108,pointer:168,marker:168
'$FZF_DEFAULT_PREVIEW'
--preview-window right:wrap
--bind "?:toggle-preview"
'

bindkey '^I' expand-or-complete
bindkey '^ ' fzf-completion
bindkey '^X^F' fasd-complete-f  # C-x C-f to do fasd-complete-f (only files)
bindkey '^X^D' fasd-complete-d  # C-x C-d to do fasd-complete-d (only directories)

# -------------------------------------
# 補完機能
# -------------------------------------
#補完に関するオプション
setopt auto_param_slash      # ディレクトリ名の補完で末尾の / を自動的に付加し、次の補完に備える
setopt mark_dirs             # ファイル名の展開でディレクトリにマッチした場合 末尾に / を付加
setopt list_types            # 補完候補一覧でファイルの種別を識別マーク表示 (訳注:ls -F の記号)
setopt auto_menu             # 補完キー連打で順に補完候補を自動で補完
setopt auto_param_keys       # カッコの対応などを自動的に補完
setopt interactive_comments  # コマンドラインでも # 以降をコメントと見なす
setopt magic_equal_subst     # コマンドラインの引数で --prefix=/usr などの = 以降でも補完できる
setopt complete_in_word      # 語の途中でもカーソル位置で補完
setopt always_last_prompt    # カーソル位置は保持したままファイル名一覧を順次その場で表示
setopt print_eight_bit       # 日本語ファイル名等8ビットを通す
setopt extended_glob         # 拡張グロブで補完(~とか^とか。例えばless *.txt~memo.txt ならmemo.txt 以外の *.txt にマッチ)
setopt globdots              # 明確なドットの指定なしで.から始まるファイルをマッチ
setopt list_packed           # リストを詰めて表示
setopt menu_complete         # インクリメント検索をディフォルト表示

# 補完候補を emacs kybind で選択出来るようにする
zstyle ':completion:*:default' menu select interactive

# 補完関数の表示を過剰にする編
zstyle ':completion:*' verbose yes
zstyle ':completion:*' completer _expand _complete _match _prefix _approximate _list _history
zstyle ':completion:*:messages' format $YELLOW'%d'$DEFAULT
zstyle ':completion:*:warnings' format $RED'No matches for:'$YELLOW' %d'$DEFAULT
zstyle ':completion:*:descriptions' format $YELLOW'completing %d'$DEFAULT
zstyle ':completion:*:corrections' format $YELLOW'%B%d '$RED'(errors: %e)%b'$DEFAULT
zstyle ':completion:*:options' description 'yes'

# グループ名に空文字列を指定すると，マッチ対象のタグ名がグループ名に使われる。
# したがって，すべての マッチ種別を別々に表示させたいなら以下のようにする
zstyle ':completion:*' group-name ''

#keybind
zmodload zsh/complist                                         # "bindkey -M menuselect"設定できるようにするため
bindkey -M menuselect '^g' .send-break                        # send-break2回分の効果
bindkey -M menuselect '^i' forward-char                       # 補完候補1つ右へ
bindkey -M menuselect '^j' .accept-line                       # accept-line2回分の効果
bindkey -M menuselect '^k' accept-and-infer-next-history      # 次の補完メニューを表示する
bindkey -M menuselect '^n' down-line-or-history               # 補完候補1つ下へ
bindkey -M menuselect '^p' up-line-or-history                 # 補完候補1つ上へ
bindkey -M menuselect '^r' history-incremental-search-forward # 補完候補内インクリメンタルサーチ
bindkey '^[f' forward-word
bindkey '^[b' backward-word
bindkey "^[u" undo
bindkey "^[r" redo

# fzf-tab settings
zstyle ':fzf-tab:*' show-group brief
zstyle ':fzf-tab:*' continuous-trigger 'ctrl-k'
FZF_TAB_COMMAND=(
    fzf
    --ansi   # Enable ANSI color support, necessary for showing groups
    --expect='$continuous_trigger,$print_query' # For continuous completion
    '--color=hl:$(( $#headers == 0 ? 108 : 255 ))'
    --nth=2,3 --delimiter='\x00'  # Don't search prefix
    --layout=reverse --height 40%
    --tiebreak=begin -m --bind=change:top,ctrl-i:toggle+down --cycle
    --preview-window hidden
    --print-query
    '--query=$query'   # $query will be expanded to query string at runtime.
    '--header-lines=$#headers' # $#headers will be expanded to lines of headers at runtime
)
zstyle ':fzf-tab:*' command $FZF_TAB_COMMAND

# ディレクトリごとに区切る
export WORDCHARS='*?_-.[]~$%^(){}<>'

# -------------------------------------
# 補正機能
# -------------------------------------
# 入力しているコマンド名が間違っている場合にもしかして：を出す。
setopt correct

# -------------------------------------
# ディレクトリ移動
# -------------------------------------
setopt auto_cd
setopt auto_pushd

# C-g でひとつ前のディレクトリへ
function cdup { zle push-line && LBUFFER='builtin cd -' && zle accept-line }
zle -N cdup
bindkey '^g' cdup

# Alt-Gで上のディレクトリに移動できる
# function cd-up { zle push-line && LBUFFER='builtin cd ..' && zle accept-line }
function cd-up { zle push-line && LBUFFER='cd ..' && zle accept-line }
zle -N cd-up
bindkey '^[g' cd-up

# Ctrl-jでディレクトリ履歴を移動できる
function cd-jump { zle push-line && LBUFFER='cd' && zle accept-line }
zle -N cd-jump
bindkey '^j' cd-jump

# Alt-jでディレクトリ履歴を移動できる
function cd-hist { zle push-line && LBUFFER='cd -' && zle accept-line }
zle -N cd-hist
bindkey '^[j' cd-hist

# -------------------------------------
# コマンド履歴
# -------------------------------------
# 失敗したコマンドは無視
__record_command() {
  typeset -g _LASTCMD=${1%%$'\n'}
  return 1
}
zshaddhistory_functions+=(__record_command)

__update_history() {
  local last_status="$?"

  # hist_ignore_space
  if [[ ! -n ${_LASTCMD%% *} ]]; then
    return
  fi

  # hist_reduce_blanks
  local cmd_reduce_blanks=$(echo ${_LASTCMD} | tr -s ' ')

  # Record the commands that have succeeded
  if [[ ${last_status} == 0 ]]; then
    print -sr -- "${cmd_reduce_blanks}"
  fi
}
precmd_functions+=(__update_history)
HISTFILE=~/.zsh_history
HISTSIZE=6000000
SAVEHIST=6000000
setopt hist_ignore_all_dups # ignore duplication command history list
setopt hist_ignore_space    # スペースから始まるコマンドを無視
setopt share_history        # share command history data
setopt hist_no_store        # historyコマンドは履歴に登録しない
# コマンド履歴検索
bindkey "^P" history-substring-search-up
bindkey "^N" history-substring-search-down

# zsh-history
autoload -Uz add-zsh-hook
add-zsh-hook precmd  "__history::history::add"
add-zsh-hook preexec "__history::substring::reset"

# TODO test 使いづらかったら消す
ZSH_HISTORY_SUBSTRING_SEARCH_HIGHLIGHT_FOUND="bg=magenta,fg=white,bold"
ZSH_HISTORY_SUBSTRING_SEARCH_HIGHLIGHT_NOT_FOUND="bg=red,fg=white,bold"
ZSH_HISTORY_SUBSTRING_SEARCH_GLOBBING_FLAGS="i"

zle -N "__history::keybind::arrow_up"
bindkey "^P" "__history::keybind::arrow_up"
zle -N "__history::keybind::arrow_down"
bindkey "^N" "__history::keybind::arrow_down"

# -------------------------------------
# キーバインディング
# -------------------------------------

# コマンドラインスタック
show_buffer_stack() {
  POSTDISPLAY="
  stack: $LBUFFER"
  zle push-line-or-edit
}
zle -N show_buffer_stack
bindkey '^s' show_buffer_stack

# リネーム機能
autoload -Uz zmv
alias zmv='noglob zmv -W'

# Ctrl-Dでシェルからログアウトしない
setopt ignoreeof

# Ctrl-[で直前コマンドの単語を挿入できる
autoload -Uz smart-insert-last-word
zstyle :insert-last-word match '*([[:alpha:]/\\]?|?[[:alpha:]/\\])*'
zle -N insert-last-word smart-insert-last-word
bindkey '^[p' insert-last-word

# tmuxでhomeとendが効かなくなる問題
bindkey '\e[1~' beginning-of-line
bindkey '\e[4~' end-of-line

# -------------------------------------
# enhancd
# -------------------------------------
ENHANCD_HOOK_AFTER_CD=ll
ENHANCD_HYPHEN_NUM=50
ENHANCD_FILTER=fzf:fzy:peco

# -------------------------------------
# Xserver start
# -------------------------------------
[[ -z $DISPLAY && $XDG_VTNR -eq 1 ]] && exec startx i3
