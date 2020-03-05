# -------------------------------------
# utils
# -------------------------------------
has() {
  type "${1:?too few arguments}" &>/dev/null
}

left-word-copy() {
  local temp
  temp=$(echo ${LBUFFER} | sed 's/ *$//')
  LBUFFER=$(echo $temp)$(echo " ")$(echo $temp | rev | cut -f1 -d " " | rev)
  zle redisplay
}
zle     -N    left-word-copy
bindkey '^v'  left-word-copy

gdopen() {
  local n
  if [[ -r "$1" ]]; then
    n=$(readlink -f "$1")
    insync open_in_gdrive "$n"
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
# fzf utils
# -------------------------------------
zmenu() {
  print -rl -- ${(ko)commands} | fzf --preview "man {}" | (nohup ${SHELL:-"/bin/sh"} &) >/dev/null 2>&1
}

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
  if selected=$(rg --column --line-number --hidden --ignore-case --no-heading --color=always '' |
    fzf --ansi --delimiter : --nth 4.. --preview '$HOME/.config/zsh/preview.sh {}'); then
    LBUFFER=${LBUFFER}$(echo $selected | awk -F':' '{print $1}')
  fi
  zle redisplay
}
zle     -N    fzf-ripgrep-widget
bindkey '\ea' fzf-ripgrep-widget

f-override() {
  local selected
  if selected=$(fasd -f | sed 's/^[0-9,.]* *//' | fzf --ansi --no-sort --tac +m); then
    LBUFFER=${LBUFFER}$selected
  fi
  zle redisplay
}
zle     -N    f-override
bindkey '\ee'  f-override

z-override() {
  if [[ -z "$*" ]]; then
    builtin cd "$(fasd_cd -d | fzf --preview-window=hidden --query="$*" -1 -0 --no-sort --tac +m | sed 's/^[0-9,.]* *//')"
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

yay-selecter() {
  yay -Sl \
  | fzf --preview 'yay -Si {2}' \
    --bind 'ctrl-x:execute(yay -Sy --noconfirm $(echo {2}))' \
    --bind 'alt-d:execute(yay -Rs --noconfirm $(echo {2}))' \
    --bind 'ctrl-r:execute(yay -Sy)' \
    --bind 'alt-c:execute(echo {2} | xclip -selection c)' \
}

rvim () {
  selected_files=$(ag $@ | fzf | awk -F : '{print "-c " $2 " " $1}') &&
  nvim $selected_files
}

fvim() {
  if [[ $@ == '-a' ]]; then
    files=$(fd -I --type file --follow --hidden --color=always --exclude  .git) &&
  else
    files=$(fd --type file --follow --hidden --color=always --exclude  .git) &&
  fi
  # wraped function timg and bat?
  selected_files=$(echo "$files" | fzf -m --ansi | tr '\n' ' ') &&

  if [[ $selected_files == '' ]]; then
    return 0
  else
    nvim $(echo "$selected_files")
  fi
}

# fzf git branch
fbr() {
  git checkout
  $(git branch -a | tr -d " " |
    fzf --height 100% --prompt "CHECKOUT BRANCH>" --preview "git log --color=always {}" |
    head -n 1 | sed -e "s/^\*\s*//g" | perl -pe "s/remotes\/origin\///g")
}

# fshow - git commit browser
fshow() {
  git log --graph --color=always \
      --format="%C(auto)%h%d %s %C(black)%C(bold)%cr" "$@" |
  fzf --ansi --no-sort --reverse --tiebreak=index --bind=ctrl-s:toggle-sort \
      --bind "ctrl-m:execute:
                (grep -o '[a-f0-9]\{7\}' | head -1 |
                xargs -I % sh -c 'git show --color=always % | less -R') << 'FZF-EOF'
                {}
                FZF-EOF"
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
  selected=$(ghq list | fzf --preview 'tree -C $(ghq root)/{} | head -200')

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
  local cols sep google_history open
  cols=$(( COLUMNS / 3 ))
  sep='{::}'

  if [ "$(uname)" = "Darwin" ]; then
    google_history="$HOME/Library/Application Support/Google/Chrome/Default/History"
    open=open
  else
    google_history="$HOME/.config/google-chrome/Default/History"
    open=xdg-open
  fi
  cp -f "$google_history" /tmp/h
  sqlite3 -separator $sep /tmp/h \
    "select substr(title, 1, $cols), url
     from urls order by last_visit_time desc" |
  awk -F $sep '{printf "%-'$cols's  \x1b[36m%s\x1b[m\n", $1, $2}' |
  fzf --ansi --multi | sed 's#.*\(https*://\)#\1#' | xargs $open > /dev/null 2> /dev/null
}

# -------------------------------------
# dig directories suggest
# -------------------------------------
dig_dir() {
    local cmd q k res
    sort="created"
    while cmd="$(
          fd --type d --follow --hidden --color=always --exclude .git \
          | fzf --ansi --query="$q" --no-sort --exit-0 \
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
# Mail suggest notmuch
# -------------------------------------
notmuchfzf() {
    local threadId
    threadId=$(notmuch search "$*" tag:archive \
    | fzf --no-sort --prompt="mailArchive-> " \
      --preview 'notmuch show --entire-thread=false  $(echo {} | cut -f1 -d " ") \
        | perl -pe "s/\n/<br>/g" | perl -pe "s/(<br>)+/<br>/g" \
        | sed -r "s/^.*body\{(.*)body\}.*$/\1/g" | perl -pe "s/<br>/\n/g"' \
      --bind 'ctrl-l:execute(notmuch show --entire-thread=false $(echo {} | cut -f1 -d " ") | bat | less -r)')

    notmuch show --entire-thread=false $(echo $threadId | cut -f1 -d ' ') | bat
}
notmuchfzfselect() {
    notmuch search "$*" tag:archive \
    | fzf --no-sort --prompt="mailArchive-> " \
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
    | fzf --no-sort --prompt="xsvpreview-> " \
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
            ctrl-x)
                if [[ ${(j: :)ok} == ${(j: :)${(@f)res}} ]]; then
                    eval '${${${(M)${+commands[gomi]}#1}:+gomi}:-rm} "${(@f)res}" 2>/dev/null'
                    ok=()
                else
                    ok=("${(@f)res}")
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
export ENHANCD_LOG="$ENHANCD_DIR/enhancd.log"
destination_directories() {
    local -a d
    if [[ -f $ENHANCD_LOG ]]; then
        d=("${(@f)"$(<$ENHANCD_LOG)"}")
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
            | while read line; do echo "${line:F:$make_dir:h}"; done \
            | reverse | awk '!a[$0]++' | reverse \
            | perl -pe 's/^(\/.*)$/\033[34m$1\033[m/' \
            | fzf --ansi --multi --tac --query="$q" \
            --no-sort --exit-0 --prompt="destination-> " \
            --preview 'tree -C {} | head -200' \
            --print-query --expect=ctrl-r,ctrl-y,ctrl-q \
            )"; do
        q="$(head -1 <<< "$cmd")"
        k="$(head -2 <<< "$cmd" | tail -1)"
        res="$(sed '1,2d;/^$/d' <<< "$cmd")"
        [ -z "$res" ] && continue
        case "$k" in
            ctrl-y)
                let make_dir--
                continue
                ;;
            ctrl-r)
                let make_dir++
                continue
                ;;
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
zle -N fzf-dir-mru-widget
bindkey '^[d' fzf-dir-mru-widget

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
            | exa -Fa --sort="$sort" "$order" --group-directories-first \
            | perl -pe 's/^(.*\/)$/\033[34m$1\033[m/' \
            | perl -pe 's/^(.*)[*@]$/$1/' \
            | fzf --ansi --multi --query="$q" \
            --header=":: $sort - $d" \
            --no-sort --exit-0 --prompt="duster-> " \
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
