# -------------------------------------
# utils
# -------------------------------------
has() {
  type "${1:?too few arguments}" &>/dev/null
}

left-word-copy() {
  local temp
  temp=$(echo ${LBUFFER} | sed 's/ *$//' | sed 's/\\ /@@@/g')
  LBUFFER=$(echo $temp)$(echo " ")$(echo $temp | rev | cut -f1 -d " " | rev)
  LBUFFER=$(echo $LBUFFER | sed 's/@@@/\\ /g')
  zle redisplay
}
zle     -N    left-word-copy
bindkey '^v'  left-word-copy

gdopen() {
  local n
  if [[ -r "$1" ]]; then
    n=$(readlink -f "$1")
    insync open-cloud "$n"
  else
    echo 'not exists file'
  fi
}

# chrome search
google() {
    local str opt
    if [ $# != 0 ]; then
        for i in $*; do
            str="$str${str:++}$i"
        done
        opt='search?num=100'
        opt="${opt}&q=${str}"
    fi
    google-chrome-stable http://www.google.co.jp/$opt
}

winopen() {
  local e n
  if [[ -r "$1" ]]; then
    n=$(wslpath -w $(wslpath -a "$1"))
    e=$(echo "$1" | sed 's/^.*\.\([^\.]*\)$/\1/')
    case "$e" in
      "ai"|"eps")
        illustrator "$n"
        ;;
      "psd")
        photoshop "$n"
        ;;
      "pdf")
        pdf "$n"
        ;;
      "jpg"|"png"|"gif")
        quicklook "$n"
        # imageviewer "$n"
        ;;
      "doc"|"docm"|"docx")
        word "$n"
        ;;
      "xls"|"xlsx"|"xlsm"|"csv")
        excel "$n"
        ;;
      "ppt"|"pptx"|"pps"|"ppsx")
        powerpoint "$n"
        ;;
    esac
  else
    echo 'not exists file'
  fi
}

quickopen() {
  local n
  if [[ -r "$1" ]]; then
    n=$(convertPathWsl "$1")
    quicklook "$n"
  else
    echo 'not exists file'
  fi
}

convertPathWsl() {
  echo $(wslpath -m $(readlink -e "$1"))
}

# -------------------------------------
# empty enter
# -------------------------------------
do-enter() {
    if [ -n "$BUFFER" ]; then
        zle accept-line
        return
    fi
    if [[ -d .git ]]; then
      if [[ -n "$(git status --porcelain)" ]]; then
        BUFFER='git status -uno --short'
        zle accept-line
        return
      fi
      zle accept-line
    else
      zle accept-line
    fi
    zle reset-prompt
}
zle -N do-enter
bindkey '^m' do-enter

# -------------------------------------
# fzf utils
# -------------------------------------
zmenu() {
  print -rl -- ${(ko)commands} | fzf --preview "man {}" | (nohup ${SHELL:-"/bin/sh"} &) >/dev/null 2>&1
}

# ALT-I - Paste the selected entry from locate output into the command line
fzf-picture-preview() {
  local selected
  if selected=$(
    fd --strip-cwd-prefix --follow --hidden --exclude .git --type f --print0 . |
    xargs -0 eza -1 -sold --color=always --no-quotes 2> /dev/null |
    fzf --ansi | sed 's/ /\\ /g' | tr '\n' ' '); then
    LBUFFER=${LBUFFER}$selected
  fi
  zle redisplay
}
zle     -N    fzf-picture-preview
bindkey '^t' fzf-picture-preview

# ALT-I - Paste the selected entry from locate output into the command line
fzf-locate-widget() {
  local selected
  if selected=$(lolcate / | fzf); then
    LBUFFER=${LBUFFER}$selected
  fi
  zle redisplay
}
zle     -N    fzf-locate-widget
bindkey '\ei' fzf-locate-widget

# ALT-I - Paste the selected entry from locate output into the command line
fzf-locate-pwd-widget() {
  local selected
  if selected=$(lolcate $(pwd) | fzf); then
    LBUFFER=${LBUFFER}$selected
  fi
  zle redisplay
}
zle     -N    fzf-locate-pwd-widget
bindkey '\eI' fzf-locate-pwd-widget

# ALT-a - ripgrep
fzf-ripgrep-widget() {
  local selected
  if selected=$(rg --column --line-number --glob=!.git --hidden --ignore-case --sort modified --no-heading --color=always '' |
    fzf --ansi --delimiter : --nth 4..,1 --tac \
    --preview 'bat --style=numbers --color=always --highlight-line {2} {1}' \
    --preview-window +{2}-/2); then
    local file=$(echo $selected | awk -F':' '{print $1}')
    local line=$(echo $selected | awk -F':' '{print $2}')
    nvim +$line $file
  fi
  zle redisplay
}
zle     -N    fzf-ripgrep-widget
bindkey '\ea' fzf-ripgrep-widget

f-override() {
  local selected
  if selected=$(fasd -f | sed 's/^[0-9,.]* *//' | fzf --ansi --tac +m); then
    LBUFFER=${LBUFFER}$selected
  fi
  zle redisplay
}
zle     -N    f-override
bindkey '\ee'  f-override

z-override() {
  if [[ -z "$*" ]]; then
    builtin cd "$(fasd_cd -d | fzf --preview-window=hidden --query="$*" -1 -0 --tac +m | sed 's/^[0-9,.]* *//')"
  else
    fasd_cd -d "$*"
  fi
}

fs() {
  local -r fmt='#{session_id}:|#S|(#{session_attached} attached)'
  { tmux display-message -p -F "$fmt" && tmux list-sessions -F "$fmt"; } \
    | awk '!seen[$1]++' \
    | column -t -s'|' \
    | fzf --preview-window=hidden -q '$' --reverse --prompt 'switch session: ' -1 \
    | cut -d':' -f1 \
    | xargs tmux switch-client -t
}

paru-selecter() {
  paru -Sl \
  | fzf --ansi --preview 'paru -Si {2}' \
    --bind 'ctrl-i:execute(paru -Sy --noconfirm $(echo {2}))' \
    --bind 'alt-d:execute(paru -Rs --noconfirm $(echo {2}))' \
    --bind 'ctrl-r:execute(paru -Sy)' \
    --bind 'alt-c:execute(echo {2} | xclip -selection c)' \
}

rvim () {
  selected_files=$(ag $@ | fzf | awk -F : '{print "-c " $2 " " $1}') &&
  nvim $selected_files
}

fvim() {
  if [[ $@ == '-a' ]]; then
    files=$( \
    fd --strip-cwd-prefix -I --follow --hidden --exclude .git --type f --print0 . | \
    xargs -0 eza -1 --no-quotes -sold --color=always --no-quotes 2> /dev/null) &&
  else
    files=$( \
    fd --strip-cwd-prefix --follow --hidden --exclude .git --type f --print0 . | \
    xargs -0 eza -1 -sold --no-quotes --color=always --no-quotes 2> /dev/null) &&
  fi

  selected_files=$(echo "$files" | fzf -m --ansi --scheme=history | tr '\n' ' ') &&

  if [[ $selected_files == '' ]]; then
    return 0
  else
    nvim $(echo "$selected_files")
  fi
}

f_history_toggle() {
  local initial_list=$(atuin search --exclude-exit 127 --reverse --format "{time}/{command}" | awk '!seen[$0]++')

  local dir; local prompt
  local is_gitdir=$(git rev-parse --is-inside-work-tree 2>/dev/null)
  if [[ $is_gitdir == 'true' ]]; then
    prompt="git"
    dir="atuin search --exclude-exit 127 --filter-mode workspace --reverse --format \\\"{time}/{command}\\\" | awk \\\"!seen[\\\\\\\$0]++\\\""
  else
    prompt="dir"
    dir="atuin search --exclude-exit 127 --filter-mode directory --reverse --format \\\"{time}/{command}\\\" | awk \\\"!seen[\\\\\\\$0]++\\\""
  fi
  local global="atuin search --exclude-exit 127 --reverse  --format \\\"{time}/{command}\\\" | awk \\\"!seen[\\\\\\\$0]++\\\""

  # 本来はdelete_timeとかで倫理削除なので不具合起きたら変更してもいいかも
  local delete="date -d {1} +%s | xargs -I $ sqlite3 ~/.local/share/atuin/history.db \\\"delete from history where timestamp like '$%'\\\""
  local update="date -d {1} +%s "
        update+="| xargs -I $ sqlite3 ~/.local/share/atuin/history.db "
        update+="\\\"update history set timestamp = CAST((julianday() - 2440587.5) * 86400000000000 AS INTEGER) where timestamp like '$%'\\\""

  local history_command
  history_command=$(
    echo "$initial_list" | fzf \
      --prompt="global >" \
      --query="${LBUFFER}" \
      --tiebreak=index \
      --preview="echo {} | sed 's|/|\n|' | bat --style=plain --language=sh --color=always" \
      --delimiter=/ \
      --with-nth=2.. \
      --preview-window hidden \
      --bind 'ctrl-r:transform:[[ $FZF_PROMPT =~ global ]] &&
              echo "change-prompt('$prompt' >)+reload('$dir')" ||
              echo "change-prompt(global >)+reload('$global')"' \
      --bind 'ctrl-s:transform:[[ $FZF_PROMPT =~ global ]] &&
              echo "execute-silent('$update')+reload('$global')" ||
              echo "execute-silent('$update')+reload('$dir')"' \
      --bind 'ctrl-x:transform:[[ $FZF_PROMPT =~ global ]] &&
              echo "execute-silent('$delete')+reload('$global')" ||
              echo "execute-silent('$delete')+reload('$dir')"' \
      --bind 'ctrl-e:execute-silent(printf {2} | xclip -selection c)' \
      | cut -d'/' -f2-
  )

  if [[ $? -ne 0 || -z "$history_command" ]]; then
    atuin history dedup --before now --dupkeep=1 &> /dev/null
    zle redisplay
    return 0
  fi

  BUFFER="$history_command"
  CURSOR=$#BUFFER
  zle redisplay
}

zle -N f_history_toggle_widget f_history_toggle
bindkey '^R' f_history_toggle_widget

# fzf git branch
fbr() {
  target_br=$(
    git branch -a | fzf --exit-0 \
        --layout=reverse \
        --info=hidden \
        --no-multi \
        --preview-window="right,65%" \
        --prompt="CHECKOUT BRANCH > " \
        --preview="echo {} | tr -d ' *' | xargs git log --decorate --abbrev-commit --format=format:'%C(blue)%h%C(reset) - %C(green)(%ar)%C(reset) %C(white)%s%C(reset) %C(dim white)- %an%C(reset) %C(yellow)%d%C(reset)' --color=always" |
    head -n 1 |
    perl -pe 's/\s//g; s/\*//g; s/remotes\/origin\///g'
  )
  if [ -n "$target_br" ]; then
    git switch $target_br
  fi
}

# fshow - git commit browser
fshow() {
  local flag
  if [[ $# = 0 ]]; then
    flag='--all'
  else
    flag=$(git rev-parse --abbrev-ref HEAD)
  fi
  git log --graph --date=short --color=always "$flag" \
      --format="%C(auto)%h %s%d %C(dim)(%cd) %cn" |
  fzf --ansi --height 100% --reverse --tiebreak=index --bind=ctrl-s:toggle-sort \
      --bind "ctrl-m:execute:
                (grep -o '[a-f0-9]\{7\}' | head -1 |
                xargs -I % sh -c 'git show --color=always % | less -R') << 'FZF-EOF'
                {}
                FZF-EOF" \
      --preview "echo {} | grep -o '[a-f0-9]\{7\}' | head -1 | xargs -I % sh -c 'git diff --color %^ %'"
}

# git staging
fadd() {
  local out q n addfiles
  while out=$(
      git status --short |
      awk '{if (substr($0,2,1) !~ / /) print $2}' |
        fzf-tmux --multi --preview 'git diff {}' --exit-0 --expect=ctrl-d); do
    q=$(head -1 <<< "$out")
    n=$[$(wc -l <<< "$out") - 1]
    addfiles=(`echo $(tail "-$n" <<< "$out")`)
    [[ -z "$addfiles" ]] && continue
    if [ "$q" = ctrl-d ]; then
      git diff --color=always $addfiles | less -R
    else
      git add $addfiles
    fi
  done
}

# git remove file
frm() {
  local out q n removefiles
  while out=$(
      git ls-files |
      fzf-tmux --multi --preview 'less {}' --exit-0 --expect=ctrl-d); do
    q=$(head -1 <<< "$out")
    n=$[$(wc -l <<< "$out") - 1]
    removefiles=(`echo $(tail "-$n" <<< "$out")`)
    [[ -z "$removefiles" ]] && continue
    if [ "$q" = ctrl-d ]; then
      git rm $removefiles
    else
      git rm --cached  $removefiles
    fi
  done
}

# process kill
pskl() {
  local pid
  if [ "$UID" != "0" ]; then
    pid=$(ps -f -u $UID | sed 1d | fzf -m --preview-window hidden | awk '{print $2}')
  else
    pid=$(ps -ef | sed 1d | fzf -m --preview-window hidden | awk '{print $2}')
  fi

  if [ "x$pid" != "x" ]
  then
    echo $pid | xargs kill -${1:-9}
  fi
}

# virt & remmina list
virtstart() {
  local rmpath flag
  flag=9
  rmpath='/home/aikawa/.local/share/remmina/'

  [[ $(sudo systemctl is-active libvirtd) == 'inactive' ]] \
    && sudo systemctl start libvirtd
  [[ $(cat /proc/mounts) != *sda5* ]] \
    && sudo mount /dev/sda5 /home/aikawa/win10

  sudo \virsh list --all >/dev/null 2>&1
  while [ $? -ne 0 ]; do
    usleep 5000
    sudo \virsh list --all >/dev/null 2>&1
  done

  sudo \virsh list --all | sed 1,2d \
  | sed -e 's/^.*running.*$//g' \
  | grep -v -e '^\s*#' -e '^\s*$' \
  | fzf --preview-window hidden --exit-0 \
  | awk '{print $2}' | (xargs -I@ sudo virsh start @ &&)

  fd . $rmpath | sed -e 's/^.*\///g' \
  | fzf --ansi --preview 'bat '$rmpath'/{}' \
  | (xargs -I@ remmina -c $rmpath/@ >/dev/null 2>&1 &)

  while [ $flag -ne 0 ]; do
    read REPLY\?"connect remmina? "${res}"? [y/n]"
    case $REPLY in
      '' | [Yy]* )
        flag=0
        ;;
      [^Yy]* )
        killall remmina
        fd . $rmpath | sed -e 's/^.*\///g' \
        | fzf --ansi --preview 'bat '$rmpath'/{}' \
        | (xargs -I@ remmina -c $rmpath/@ >/dev/null 2>&1 &)
    esac
  done
}

# virt stop
virtstop() {
  local ret
  sudo \virsh list | sed 1,2d \
  | grep -v -e '^\s*#' -e '^\s*$' \
  | fzf --preview-window hidden --exit-0 \
  | awk '{print $2}' | (xargs -I@ sudo virsh destroy @ &&)

  [[ -z $(sudo \virsh list | sed 1,2d | grep -v -e '^\s*#' -e '^\s*$') ]] && \
    [[ $(sudo systemctl is-active libvirtd) != 'inactive' ]] \
      && sudo systemctl stop libvirtd; killall remmina
  if [[ $(cat /proc/mounts) == *sda5* ]]; then
    sudo umount /home/aikawa/win10 >/dev/null 2>&1
    while [ $? -ne 0 ]; do
      sleep 1
      sudo umount /home/aikawa/win10 >/dev/null 2>&1
    done
  fi
}

# fdg - ghq
fdg() {
  local selected
  selected=$(ghq list | fzf --scheme=history --preview 'tree -C $(ghq root)/{} | head -200')

  if [ "x$selected" != "x" ]; then
    cd $(ghq root)/$selected
  fi
  zle accept-line
}
zle -N fdg
bindkey '^z' fdg

ghq-update() {
  ghq list | sed -E 's/^[^\/]+\/(.+)/\1/' | xargs -n 1 -P 10 ghq get -u
}

ghistory() {
  local cols sep history_file open
  cols=$(( COLUMNS / 3 ))
  sep='{::}'

  if [ "$(uname)" = "Darwin" ]; then
    history_file="$HOME/Library/Application Support/Google/Chrome/Default/History"
    open=open
  else
    # Try Google Chrome first, then fallback to Vivaldi
    if [ -f "$HOME/.config/google-chrome/Default/History" ]; then
      history_file="$HOME/.config/google-chrome/Default/History"
    elif [ -f "$HOME/.config/vivaldi/Default/History" ]; then
      history_file="$HOME/.config/vivaldi/Default/History"
    else
      echo "No browser history file found"
      return 1
    fi
    open=xdg-open
  fi

  cp -f "$history_file" /tmp/h
  sqlite3 -separator $sep /tmp/h \
    "select substr(title, 1, $cols), url
     from urls order by last_visit_time desc" |
  awk -F $sep '{printf "%-'$cols's  \x1b[36m%s\x1b[m\n", $1, $2}' |
  fzf --ansi --multi --scheme=history | sed 's#.*\(https*://\)#\1#' | xargs $open > /dev/null 2> /dev/null
}

vhistory() {
  local cols sep google_history open
  cols=$(( COLUMNS / 3 ))
  sep='{::}'

  google_history="$HOME/.config/vivaldi/Default/History"
  open=xdg-open

  cp -f "$google_history" /tmp/h
  sqlite3 -separator $sep /tmp/h \
    "select substr(title, 1, $cols), url
     from urls order by last_visit_time desc" |
  awk -F $sep '{printf "%-'$cols's  \x1b[36m%s\x1b[m\n", $1, $2}' |
  fzf --ansi --multi --scheme=history | sed 's#.*\(https*://\)#\1#' | xargs $open > /dev/null 2> /dev/null
}

# -------------------------------------
# dig directories suggest
# -------------------------------------
dig_dir() {
    local cmd q k res
    sort="created"
    while cmd="$(
          fd --strip-cwd-prefix --type d --follow --hidden --color=always --exclude .git \
          | fzf --ansi --query="$q" --exit-0 \
          --bind 'alt-c:execute(echo {} | xclip -selection c)' \
          --print-query --expect=ctrl-j,ctrl-b,ctrl-g,ctrl-d \
          )"; do
        q="$(head -1 <<< "$cmd")"
        k="$(head -2 <<< "$cmd" | tail -1)"
        res="$(sed '1,2d;/^$/d' <<< "$cmd")"
        case "$k" in
          ctrl-j)
            cd ${res}
            zle accept-line
            continue
            ;;
          ctrl-g)
            builtin cd -
            zle accept-line
            continue
            ;;
          ctrl-b)
            builtin cd ../
            zle accept-line
            continue
            ;;
          ctrl-d)
            cd ${res}
            zle accept-line
            break
            ;;
          *)
            LBUFFER=${LBUFFER}${res}
            break
            ;;
        esac
    done
    zle redisplay
}
zle     -N    dig_dir
bindkey '\ec'  dig_dir

# -------------------------------------
# hybrid history
# -------------------------------------
hybrid_history() {
    local cmd k res num c c1 c2 q
    c1="fc -rl 1 |"
    c1+="fzf --preview-window=hidden -n2..,.. --scheme=history "
    c1+="--ansi --query=${(qqq)LBUFFER} --exit-0 "
    c1+="--bind 'alt-c:execute(echo {} | xclip -selection c)'"
    c1+="--print-query --expect=ctrl-r"

    c2="command history search $ZSH_HISTORY_FILTER_OPTIONS"

    c=$c1
    while cmd="$(
      eval $c
          )"; do
        k="$(head -2 <<< "$cmd" | tail -1)"
        q="$(head -1 <<< "$cmd")"
        res="$(sed '1,2d;/^$/d' <<< "$cmd")"
        case "$k" in
          ctrl-r)
            if [[ $c =~ "^fc" ]]; then
              c=$c2
              if [[ -n "$q" ]]; then
                c="$c --query "$q""
              fi
              zle redisplay
              continue
            fi
            ;;
          *)
            if [[ $res ]]; then
              num=$(echo "${res}")
              zle vi-fetch-history -n $num
            else
              LBUFFER="$cmd"
              if [[ -n $cmd ]]; then
                BUFFER="$cmd"
                CURSOR=$#BUFFER
              fi
            fi
            break
            ;;
        esac
    done
    zle redisplay
}

zle     -N    hybrid_history
# bindkey '^r'  hybrid_history

# -------------------------------------
# Mail suggest notmuch
# -------------------------------------
notmuchfzf() {
    local threadId
    threadId=$(notmuch search "$*" tag:archive \
    | fzf --prompt="mailArchive-> " \
      --preview 'notmuch show --entire-thread=false  $(echo {} | cut -f1 -d " ") \
        | perl -pe "s/\n/<br>/g" | perl -pe "s/(<br>)+/<br>/g" \
        | sed -r "s/^.*body\{(.*)body\}.*$/\1/g" | perl -pe "s/<br>/\n/g"' \
      --bind 'ctrl-l:execute(notmuch show --entire-thread=false $(echo {} | cut -f1 -d " ") | bat | less -r)')

    notmuch show --entire-thread=false $(echo $threadId | cut -f1 -d ' ') | bat
}
notmuchfzfselect() {
    notmuch search "$*" tag:archive \
    | fzf --prompt="mailArchive-> " \
      --preview-window down:60% --height 100% \
      --preview 'notmuch show --entire-thread=false $(echo {} | cut -f1 -d " ") \
        | perl -pe "s/\n/<br>/g" | perl -pe "s/(<br>)+/<br>/g" \
        | sed -r "s/^.*body\{(.*)body\}.*$/\1/g" | perl -pe "s/<br>/\n/g"' \
      --bind 'ctrl-l:execute(notmuch show --entire-thread=false $(echo {} | cut -f1 -d " ") | bat | less -r)' \
      --bind 'ctrl-v:execute(notmuch show --entire-thread=false $(echo {} | cut -f1 -d " ") | nvim -R)' \
      --bind 'alt-c:execute(echo {} | cut -f1 -d " " | xclip -selection c)'
}

# -------------------------------------
# CSV viewer
# -------------------------------------
csvfzfviewer() {
    nl -n ln -w 1 -s "," "$*" | xsv cat rows \
    | fzf --prompt="xsvpreview-> " \
      --preview-window right:30% --height 100% \
      --preview 'xsv slice -s $(expr $(echo {} | cut -f1 -d ",") - 2) \
        -e $(expr $(echo {} | cut -f1 -d ",") - 1) '$*'  | xsv flatten' \
      --bind 'alt-c:execute(echo {} | cut -f1 -d " " | xclip -selection c)'
}

# -------------------------------------
# MRU
# -------------------------------------
mru() {
    local -a f
    f=(
    ~/.cache/neomru/file(N)
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
            | fzf --ansi --multi --query="$q" --tiebreak=history  \
            --exit-0 --prompt="MRU> " \
            --preview "pygmentize -g  {}" \
            --print-query --expect=ctrl-v,ctrl-x,ctrl-l,ctrl-q,ctrl-r
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
            ctrl-v)
                nvim -p "${(@f)res}" < /dev/tty > /dev/tty
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
fzf-file-mru-widget() {
  LBUFFER="${LBUFFER}$(mru)"
  local ret=$?
  zle reset-prompt
  return $ret
}
zle -N fzf-file-mru-widget
bindkey '^[E' fzf-file-mru-widget

reverse() {
  perl -e 'print reverse <>' ${@+"$@"}
}

# -------------------------------------
# Directory suggest
# -------------------------------------
enhancd_useful() {
  local -a result
  result=(
    ${$(
      __enhancd::history::list |
      awk -F/ '{OFS="/"; $NF="\x1b[1;34m"$NF"\x1b[0m"} 1' |
      fzf --tiebreak=index \
        --multi --ansi \
        --expect=ctrl-a \
        --bind 'ctrl-e:execute-silent(printf {} | xclip -selection c -in)'
    )}
  )

  if [[ -z "$result" ]]; then
    zle reset-prompt
    return
  fi

  local key
  local -a dirs

  if [[ "${result[1]}" == "ctrl-a" ]]; then
    key="ctrl-a"
    dirs=("${(@)result[2,-1]}")
  else
    key="enter"
    dirs=("${(@)result}")
  fi

  case "$key" in
    ctrl-a)
      local dir_string="${(j: :)dirs}"
      LBUFFER+=${dir_string//$'\r'/}
      zle reset-prompt
      ;;
    *)
      local target_dir=${dirs[-1]//$'\r'/}
      if [[ -n "$target_dir" ]]; then
        cd ${target_dir}
        zle send-break
      fi
      ;;
  esac
}

zle -N enhancd_useful
bindkey '^j' enhancd_useful

export ENHANCD_LOG="/home/aikawa/.config/enhancd/enhancd.log"
destination_directories() {
    local -a d
    if [[ -f $ENHANCD_LOG ]]; then
        while IFS= read -r line; do
          d+=("$line")
        done < "$ENHANCD_LOG"
    else
        d=(
        ${GOPATH%%:*}/src/github.com/**/*~**/*\.git/**(N-/)
        # $DOTPATH/**/*~$DOTPATH/*\.git/**(N-/)
        $HOME/Dropbox(N-/)
        $HOME
        $OLDPWD
        $($DOTPATH/bin/tfp(N))
        )
    fi
    if [[ $#d -eq 0 ]]; then
        echo "There is no available directory" >&2
        return 1
    fi

    local cmd q k res
    local line make_dir
    while : ${make_dir:=0}; cmd="$(
        echo "${(F)d}" \
            | __enhancd::filter::exists \
            | reverse | awk '!a[$0]++' | reverse \
            | perl -pe 's/^(\/.*)$/\033[34m$1\033[m/' \
            | fzf --ansi --multi --tac --query="$q" \
            --exit-0 --prompt="dir-> " \
            --preview 'tree -C {} | head -200' \
            --print-query --expect=ctrl-q \
            )"; do
        q="$(head -1 <<< "$cmd")"
        k="$(head -2 <<< "$cmd" | tail -1)"
        res="$(sed '1,2d;/^$/d' <<< "$cmd")"
        [ -z "$res" ] && continue
        case "$k" in
            ctrl-q)
                echo "${(@f)res}" >/dev/tty
                break
                ;;
            *)
                echo "${(@f)res}"
                break
                ;;
        esac
    done
}
fzf-dir-mru-widget() {
  LBUFFER="${LBUFFER}$(destination_directories)"
  local ret=$?
  zle reset-prompt
  return $ret
}
# zle -N fzf-dir-mru-widget
# bindkey '^[d' fzf-dir-mru-widget

# -------------------------------------
# Dust suggest
# -------------------------------------
duster() {
    local cmd q k res
    local line sort order d
    sort="created"
    order="--reverse"
    while cmd="$(
        [ "$order" = -F ] && d="ASC" || d="DESC"
        echo "${(F)d}" \
            | eza -Fa --sort="$sort" "$order" --group-directories-first \
            | perl -pe 's/^(.*\/)$/\033[34m$1\033[m/' \
            | perl -pe 's/^(.*)[*@]$/$1/' \
            | fzf --ansi --multi --query="$q" \
            --header=":: $sort - $d" \
            --exit-0 --prompt="duster-> " \
            --preview "pygmentize -g  {}" \
            --print-query --expect=ctrl-s,ctrl-u,ctrl-e,enter,ctrl-r,ctrl-l,ctrl-d,ctrl-b,ctrl-v,"-" \
            )"; do
        q="$(head -1 <<< "$cmd")"
        k="$(head -2 <<< "$cmd" | tail -1)"
        res="$(sed '1,2d;/^$/d' <<< "$cmd")"
        [ -z "$res" ] && continue
        case "$k" in
            "?")
                cat <<HELP > /dev/tty
keybind:
  Enter  change directory or echo selected
  ctrl-b history back dir
  -  history selected
  ctrl-s  size sort
  ctrl-u  created sort
  ctrl-e  modified sort
  ctrl-d  remove files and dir
  ctrl-q  echo select files or dir
HELP
            continue
            ;;
          "-")
            cd -
            continue
            ;;
          ctrl-b)
            cd ../
            continue
            ;;
          ctrl-s)
            sort="size"
            continue
            ;;
          ctrl-u)
            sort="created"
            continue
            ;;
          ctrl-e)
            sort="modified"
            continue
            ;;
          ctrl-v)
            nvim ${res}
            continue
            ;;
          ctrl-l)
            quickopen ${res}
            ;;
          ctrl-r)
            # -F is dammy
            [ "$order" = -F ] && order="--reverse" || order="-F"
            continue
            ;;
          ctrl-d)
            read REPLY\?"you delete "${res}"? [y/n]"
            case $REPLY in
              '' | [Yy]* )
                eval '${${${(M)${+commands[gomi]}#1}:+gomi}:-rm} "${(@f)res}" 2>/dev/null'
                ;;
              [^Yy]* )
                echo "no "${res}" delete!"
            esac
            continue
            ;;
          ctrl-q)
            echo "${(@f)res}" >/dev/tty
            break
            ;;
          *)
            if [ -d ${res} ]; then
              cd ${res}
              continue
            else
              echo "${(@f)res}"
              break
            fi
            ;;
        esac
    done
}

# -------------------------------------
# tmux
# -------------------------------------
rtmux() {
  cd ~/.local/share/tmux/resurrect/ || exit # Your save path
  find . | sort | tail -n 1 | xargs rm
  find . -printf "%f\n" | sort | tail -n 1 | xargs -I {} ln -sf {} last
  cd - || exit
}

function ftmux_resurrect() {
  local pre_dir=$(pwd);
  if [ -e "$HOME/.tmux/resurrect" ]; then
    cd ~/.tmux/resurrect
  elif [ -e "$HOME/.local/share/tmux/resurrect" ]; then
    cd ~/.local/share/tmux/resurrect
  else
    echo "resurrect directory not found"
    return 1
  fi
  local can_bat='type bat > /dev/null'
  local bat_command='bat \
    --color=always \
    --theme=gruvbox-dark {}'
  local alt_command='cat {} | head -200'
  local fzf_command="fzf-tmux -p 80% \
    --preview '( ($can_bat) && $bat_command || ($alt_command) ) 2> /dev/null' \
    --preview-window 'down,60%,wrap,+3/2,~3'"
  local result=$(
    find . -name 'tmux_resurrect_[0-9]*.txt' \
    | sort -r \
    | eval $fzf_command
  )
  if [ -n "$result" ]; then
    ln -sf $result last
    echo "link!"
  else
    echo "No link..."
  fi
  cd $pre_dir
}
