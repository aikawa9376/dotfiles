# -------------------------------------
# zplug
# -------------------------------------
source ~/.zplug/init.zsh
# zsh-completions
zplug "zsh-users/zsh-completions"
# zsh-history-substring-search
zplug "zsh-users/zsh-history-substring-search"
# zsh-syntax-highlighting
zplug "zsh-users/zsh-syntax-highlighting", defer:2
# autosuggestions
zplug "zsh-users/zsh-autosuggestions"
# zaw
zplug "zsh-users/zaw"
# k
zplug "supercrabtree/k"
# enhancd
zplug "b4b4r07/enhancd", use:init.sh
# ゴミ箱機能
zplug "b4b4r07/zsh-gomi", if:"which fzf"
# git plugin
zplug "plugin/git", from:oh-my-zsh
# 256 coloer ???
zplug "chrissicool/zsh-256color"
# pair auto
zplug "hlissner/zsh-autopair", defer:3
# fzf-widgets
zplug "ytet5uy4/fzf-widgets", if:"which fzf"
# tmux fzf
zplug "arks22/tmuximum", as:command
# zplug selfupdate
zplug 'zplug/zplug', hook-build:'zplug --self-manage'

if ! zplug check --verbose; then
  printf "Install? [y/N]: "
  if read -q; then
    echo; zplug install
  fi
fi
# プラグインを読み込み、コマンドにパスを通す
zplug load --verbose

# -------------------------------------
# 基本設定
# -------------------------------------
export PATH="/usr/local/bin:$PATH"
export TERM='xterm-256color'
export EDITOR='nvim'
export WCWIDTH_CJK_LEGACY='yes'
export ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE="fg=cyan"

# go lang
export GOPATH="$HOME/go"
export PATH="$GOPATH/bin:$PATH"

# local settings
case ${OSTYPE} in
  linux*)
    # homebrew
    export BREWPATH="/home/linuxbrew/.linuxbrew/bin"
    export PATH="$BREWPATH:$PATH"
esac

stty stop undef
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
loadlib $ZCONFDIR/zsh-alias.zsh
loadlib $ZCONFDIR/zsh-vimode.zsh
loadlib $ZCONFDIR/zsh-functions.zsh
loadlib $ZCONFDIR/zsh-bookmark.zsh

# -------------------------------------
# prompt
# -------------------------------------
autoload -Uz vcs_info
setopt prompt_subst
setopt combining_chars

zstyle ':vcs_info:git:*' check-for-changes true
zstyle ':vcs_info:git:*' unstagedstr '!'
zstyle ':vcs_info:git:*' stagedstr '+'
zstyle ':vcs_info:*' formats ' %c%u(%s:%b)'
zstyle ':vcs_info:*' actionformats ' %c%u(%s:%b|%a)'

precmd () {
  # 1行あける
  print
  # バージョン管理されてた場合、ブランチ名
  inside_git_repo="$(git rev-parse --is-inside-work-tree 2>/dev/null)"
  if [ "$inside_git_repo" ]; then
    vcs_info
    psvar=()
    LANG=jp_JP.UTF-8 vcs_info
    [[ -n "$vcs_info_msg_0_" ]] && psvar[1]="$vcs_info_msg_0_"
    local left="%B%F{white}>>%B%F{blue}%~%f%b%B%F{green}%1(v|%1v|)%f%b"
  else
    local left="%B%F{white}>>%B%F{blue}%~%f%b"
  fi
  local right="%B%F{white}[%m:%B%F{yellow}%D %*%B%F{white}]"
  # スペースの長さを計算
  # テキストを装飾する場合、エスケープシーケンスをカウントしないようにします
  local invisible='%([BSUbfksu]|([FK]|){*})'
  local leftwidth=${#${(S%%)left//$~invisible/}}
  local rightwidth=${#${(S%%)right//$~invisible/}}
  local padwidth=$(($COLUMNS - ($leftwidth + $rightwidth) % $COLUMNS))

  print -P $left${(r:$padwidth:: :)}$right
}

# -------------------------------------
# fzf
# -------------------------------------
[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh
export FZF_DEFAULT_COMMAND='fd --type file --follow --hidden --color=always --exclude .git'
export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
export FZF_CTRL_T_OPTS='--preview-window right:wrap --preview "pygmentize -O style="solarizeddark" -f console256 -g  {}"'
export FZF_ALT_C_COMMAND='fd --type directory --follow --hidden --color=always --exclude .git'
export FZF_ALT_C_OPTS="--preview 'tree -C {} | head -200'"
export FZF_COMPLETION_TRIGGER=''
export FZF_DEFAULT_OPTS='
--height 40%
--reverse
--extended
--ansi
--history '$HOME'/.fzf/history
--bind alt-k:preview-up,alt-j:preview-down,ctrl-n:down,ctrl-p:up
--bind alt-p:previous-history,alt-n:next-history,ctrl-k:kill-line
--color dark,hl:34,hl+:40,bg+:235,fg+:15
--color info:108,prompt:109,spinner:108,pointer:168,marker:168
'

bindkey "^I" expand-or-complete
bindkey "^[[Z" fzf-completion
# -------------------------------------
# 補完機能
# -------------------------------------
# 補完機能の強化
autoload -U compinit
compinit

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
zstyle ':completion:*:descriptions' format $YELLOW'completing %B%d%b'$DEFAULT
zstyle ':completion:*:corrections' format $YELLOW'%B%d '$RED'(errors: %e)%b'$DEFAULT
zstyle ':completion:*:options' description 'yes'

# グループ名に空文字列を指定すると，マッチ対象のタグ名がグループ名に使われる。
# したがって，すべての マッチ種別を別々に表示させたいなら以下のようにする
zstyle ':completion:*' group-name ''

#LS_COLORSを設定しておく
export LS_COLORS="$(vivid generate ayu)"
export EXA_COLORS='di=01;34:ln=35:so=32:pi=33:ex=04:bd=46;34:cd=43;34:su=41;30:sg=46;30:tw=42;30:ow=04;01;34'
# eval $(dircolors $HOME/dotfiles/alacritty/dircolors.256dark)
# eval $(dircolors $HOME/dotfiles/alacritty/dir_colors)
#ファイル補完候補に色を付ける
zstyle ':completion:*' list-colors ${(s.:.)LS_COLORS}

# ディレクトリごとに区切る
WORDCHARS='*?_-.[]~=&;!#$%^(){}<>'

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

# -------------------------------------
# 補正機能
# -------------------------------------
# 入力しているコマンド名が間違っている場合にもしかして：を出す。
setopt correct

# -------------------------------------
# ディレクト移動
# -------------------------------------
setopt auto_cd
setopt auto_pushd

# C-g でひとつ前のディレクトリへ
function cdup { zle push-line && LBUFFER='builtin cd -' && zle accept-line }
zle -N cdup
bindkey '^g' cdup

# Alt-Gで上のディレクトリに移動できる
function cd-up { zle push-line && LBUFFER='builtin cd ..' && zle accept-line }
zle -N cd-up
bindkey '^[g' cd-up

function rvim () {
  selected_files=$(ag $@ | fzf | awk -F : '{print "-c " $2 " " $1}') &&
  nvim $selected_files
}

function fvim() {
  if [[ $@ == '-a' ]]; then
    files=$(fd -I --type file --follow --hidden --color=always --exclude  .git) &&
  else
    files=$(fd --type file --follow --hidden --color=always --exclude  .git) &&
  fi
  selected_files=$(echo "$files" | fzf -m --preview 'head -100 {}' | tr '\n' ' ') &&

  if [[ $selected_files == '' ]]; then
    return 0
  else
    nvim $(echo "$selected_files")
  fi
}

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
bindkey '^[' insert-last-word

bindkey '^[x' zaw

# -------------------------------------
# Xserver関係
# -------------------------------------
# umask 022
# export DISPLAY=localhost:0.0

# -------------------------------------
# ssh-agent
# -------------------------------------
if [ -f ~/.ssh-agent ]; then
    . ~/.ssh-agent
fi
if [ -z "$SSH_AGENT_PID" ] || ! kill -0 $SSH_AGENT_PID; then
    ssh-agent > ~/.ssh-agent
    . ~/.ssh-agent
fi
ssh-add -l >& /dev/null || ssh-add
