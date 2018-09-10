# -------------------------------------
# zplug
# -------------------------------------
source ~/.zplug/init.zsh
# zsh-completions
zplug "zsh-users/zsh-completions"
# zsh-syntax-highlighting
zplug "zsh-users/zsh-syntax-highlighting"
# anyframe
zplug "mollifier/anyframe"
# k
zplug "supercrabtree/k"
# autosuggestions
zplug "zsh-users/zsh-autosuggestions"
# enhancd
zplug "b4b4r07/enhancd"
# git plugin
#zplug "plugin/git", from:oh-my-zsh
# 256 coloer ???
zplug "chrissicool/zsh-256color"
# pair auto
zplug "hlissner/zsh-autopair", defer:2
# zplug selfupdate
zplug 'zplug/zplug', hook-build:'zplug --self-manage'
# ゴミ箱機能
zplug "b4b4r07/zsh-gomi", if:"which fzf"

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
export ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE="fg=cyan"
export TERM='xterm-256color'

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
  # カレントディレクトリ
  local left="%B%F{white}>>[%n@%m]"
  # バージョン管理されてた場合、ブランチ名
  vcs_info
  psvar=()
  LANG=jp_JP.UTF-8 vcs_info
  [[ -n "$vcs_info_msg_0_" ]] && psvar[1]="$vcs_info_msg_0_"
  local right="%B%F{green}%1(v|%1v|)%f%b %B%F{blue}%~%f%b %B%F{yellow}%D %*"
  # スペースの長さを計算
  # テキストを装飾する場合、エスケープシーケンスをカウントしないようにします
  local invisible='%([BSUbfksu]|([FK]|){*})'
  local leftwidth=${#${(S%%)left//$~invisible/}}
  local rightwidth=${#${(S%%)right//$~invisible/}}
  local padwidth=$(($COLUMNS - ($leftwidth + $rightwidth) % $COLUMNS))

  print -P $left${(r:$padwidth:: :)}$right
}
PROMPT="%B%F{white}>%f%b "
TRAPALRM() {
  zle reset-prompt
}

# -------------------------------------
# fzf 
# -------------------------------------
[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh
export FZF_DEFAULT_COMMAND='rg --files --hidden --follow --glob "!.git/*"'
export FZF_DEFAULT_OPTS='
--height 40% 
--reverse 
--border
--color dark,hl:34,hl+:40,bg+:235,fg+:15 
--color info:108,prompt:109,spinner:108,pointer:168,marker:168
'

# -------------------------------------
# 補完機能
# -------------------------------------
# 補完機能の強化
autoload -U compinit
compinit
#autoload predict-on
#predict-on

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

bindkey "^I" menu-complete   # 展開する前に補完候補を出させる(Ctrl-iで補完するようにする)

# 補完候補を ←↓↑→ でも選択出来るようにする
zstyle ':completion:*:default' menu select=2

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
export LS_COLORS='di=34:ln=35:so=32:pi=33:ex=31:bd=46;34:cd=43;34:su=41;30:sg=46;30:tw=42;30:ow=43;30'
#ファイル補完候補に色を付ける
zstyle ':completion:*' list-colors ${(s.:.)LS_COLORS}

# -------------------------------------
# 補正機能
# -------------------------------------
## 入力しているコマンド名が間違っている場合にもしかして：を出す。
setopt correct

# -------------------------------------
# ディレクト移動
# -------------------------------------
setopt auto_cd
setopt auto_pushd

function agvim () {   
  vim $(ag $@ | fzf | awk -F : '{print "-c " $2 " " $1}') 
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
autoload history-search-end
zle -N history-beginning-search-backward-end history-search-end
zle -N history-beginning-search-forward-end history-search-end
bindkey "^P" history-beginning-search-backward-end
bindkey "^N" history-beginning-search-forward-end

# -------------------------------------
# MRU
# -------------------------------------
mru() {
    local -a f
    f=(
    ~/.vim_mru_files(N)
    ~/.unite/file_mru(N)
    ~/.cache/ctrlp/mru/cache.txt(N)
    ~/.frill(N)
    )
    if [[ $#f -eq 0 ]]; then
        echo "There is no available MRU Vim plugins" >&2
        return 1
    fi

    local cmd q k res
    local line ok make_dir i arr
    local get_styles styles style
    while : ${make_dir:=0}; ok=("${ok[@]:-dummy_$RANDOM}"); cmd="$(
        cat <$f \
            | while read line; do [ -e "$line" ] && echo "$line"; done \
            | while read line; do [ "$make_dir" -eq 1 ] && echo "${line:h}/" || echo "$line"; done \
            | awk '!a[$0]++' \
            | perl -pe 's/^(\/.*\/)(.*)$/\033[34m$1\033[m$2/' \
            | fzf --ansi --multi --query="$q" \
            --no-sort --exit-0 --prompt="MRU> " \
            --print-query --expect=ctrl-v,ctrl-x,ctrl-l,ctrl-q,ctrl-r,"?"
            )"; do
        q="$(head -1 <<< "$cmd")"
        k="$(head -2 <<< "$cmd" | tail -1)"
        res="$(sed '1,2d;/^$/d' <<< "$cmd")"
        [ -z "$res" ] && continue
        case "$k" in
            "?")
                cat <<HELP > /dev/tty
usage: vim_mru_files
    list up most recently files
keybind:
  ctrl-q  output files and quit
  ctrl-l  less files under the cursor
  ctrl-v  vim files under the cursor
  ctrl-r  change view type
  ctrl-x  remove files (two-step)
HELP
                return 1
                ;;
            ctrl-r)
                if [ $make_dir -eq 1 ]; then
                    make_dir=0
                else
                    make_dir=1
                fi
                continue
                ;;
            ctrl-l)
                export LESS='-R -f -i -P ?f%f:(stdin). ?lb%lb?L/%L.. [?eEOF:?pb%pb\%..]'
                arr=("${(@f)res}")
                if [[ -d ${arr[1]} ]]; then
                    ls -l "${(@f)res}" < /dev/tty | less > /dev/tty
                else
                    if has "pygmentize"; then
                        get_styles="from pygments.styles import get_all_styles
                        styles = list(get_all_styles())
                        print('\n'.join(styles))"
                        styles=( $(sed -e 's/^  *//g' <<<"$get_styles" | python) )
                        style=${${(M)styles:#solarized}:-default}
                        export LESSOPEN="| pygmentize -O style=$style -f console256 -g %s"
                    fi
                    less "${(@f)res}" < /dev/tty > /dev/tty
                fi
                ;;
            ctrl-x)
                if [[ ${(j: :)ok} == ${(j: :)${(@f)res}} ]]; then
                    eval '${${${(M)${+commands[gomi]}#1}:+gomi}:-rm} "${(@f)res}" 2>/dev/null'
                    ok=()
                else
                    ok=("${(@f)res}")
                fi
                ;;
            ctrl-v)
                vim -p "${(@f)res}" < /dev/tty > /dev/tty
                ;;
            ctrl-q)
                echo "$res" < /dev/tty > /dev/tty
                return $status
                ;;
            *)
                echo "${(@f)res}"
                break
                ;;
        esac
    done
}

# -------------------------------------
# エイリアス
# -------------------------------------
case ${OSTYPE} in
  darwin*)
    alias ctags="`brew --prefix`/bin/ctags"
    alias l='ls -GAF'
    alias ls='ls -G'
    alias lsa='ls -GAFltr'
    ;;
  linux*)
    alias l='ls -GAF --color=auto'
    alias ls='ls -G --color=auto'
    alias lsa='ls -GAFltr --color=auto'
esac

if ((${+commands[nodejs]})); then
  alias node='nodejs'
fi

