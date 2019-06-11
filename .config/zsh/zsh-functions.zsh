# -------------------------------------
# utils
# -------------------------------------
has() {
  type "${1:?too few arguments}" &>/dev/null
}

zmenu() {
  print -rl -- ${(ko)commands} | fzf | (nohup ${SHELL:-"/bin/sh"} &) >/dev/null 2>&1
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

left-word-copy() {
  LBUFFER=${LBUFFER}$(echo " ")$(echo ${LBUFFER} | rev | cut -f1 -d " " | rev)
  zle redisplay
}
zle     -N    left-word-copy
bindkey '^v'  left-word-copy

choice-child-dir() {
  local selected
  if selected=$(fd --type d --follow --hidden --color=always --exclude .git | fzf --ansi); then
    LBUFFER=${LBUFFER}$selected
  fi
  zle redisplay
}
zle     -N    choice-child-dir
bindkey '^j'  choice-child-dir

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
# Mail suggest notmuch
# -------------------------------------
notmuchfzf() {
    local cmd q k res
    local line make_dir
    while : ${make_dir:=0}; cmd="$(
        echo "${(F)d}" \
            | notmuch search "$*" tag:archive \
            | fzf --no-sort --prompt="mailArchive-> " \
            --preview 'notmuch show $(echo {} | cut -f1 -d " ")' \
            --print-query --expect=ctrl-y \
            --bind 'ctrl-l:execute(less -f {})' \
            )"; do
        k="$(head -2 <<< "$cmd" | tail -1)"
        res="$(sed '1,2d;/^$/d' <<< "$cmd")"
        case "$k" in
            ctrl-y)
                $(echo "${res}") | copytex
                continue
                ;;
            *)
                notmuch show $(echo "${res}" | cut -f1 -d ' ') | bat
                break
                ;;
        esac
    done
}

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

# -------------------------------------
# Finder
# -------------------------------------
finder() {
  local cmd q k res
  local CLI_FINDER_MODE CLI_FINDER_DIR CLI_FINDER_LEVEL
  dir="${1:-$PWD}"
  CLI_FINDER_MODE="tree"
  CLI_FINDER_DIR="file"
  CLI_FINDER_LEVEL="9"
  while out="$(
    if [[ $CLI_FINDER_MODE == "tree" ]]; then \
      if [[ $CLI_FINDER_DIR == "file" ]]; then \
        tree -a -C -I ".git" --dirsfirst -L $CLI_FINDER_LEVEL --charset=C $dir; \
      else
        tree -ad -C -I ".git" --dirsfirst -L $CLI_FINDER_LEVEL --charset=C $dir; \
        fi
      else \
        (builtin cd $dir; \
        find . -path '*.git*' -prune -o -print \
        | while read line; do [ -d "$line" ] && echo "$line/" || echo "$line"; done \
        | sed -e 's|^\./||;/^$/d' \
        | perl -pe 's/^(.*\/)(.*)$/\033[34m$1\033[m$2/' \
        ); \
      fi \
      | fzf --ansi --no-sort --reverse \
      --height=100% \
      --query="$q" --print-query \
      --expect=ctrl-b,ctrl-v,ctrl-l,ctrl-r,ctrl-c,ctrl-i,ctrl-d,alt-q,enter,"-","1","2","3","9"
      )"; do

      q="$(head -1 <<< "$out")"
      k="$(head -2 <<< "$out" | tail -1)"
      res="$(sed '1,2d;/^$/d' <<< "$out")"
      [ -z "$res" ] && continue

      t="$(
      if [[ $CLI_FINDER_MODE == "tree" ]]; then
        ok=0
        arr=(${(@f)"$(tree -a -I ".git" --charset=C $dir)"})
        for ((i=1; i<=$#arr; i++)); do
          if [[ $arr[i] == $res ]]; then
            n=$i
            break
          fi
        done
        arr=(${(@f)"$(tree -f -a -I ".git" --charset=C $dir)"})
        perl -pe 's/^(( *(\||`)( |`|-)+)+)//' <<<$arr[n] \
          | sed -e 's/ -> .*$//'
      else
        echo $dir/$res
      fi
      )"

      case "$k" in
        "-")
          cd -
          dir="${1:-$PWD}"
          continue
          ;;
        [1-9])
          CLI_FINDER_LEVEL="$k"
          continue
          ;;
        ctrl-b)
          cd ../
          dir="${1:-$PWD}"
          continue
          ;;
        ctrl-r)
          if [[ $CLI_FINDER_MODE == "list" ]]; then
            CLI_FINDER_MODE="tree"
          else
            CLI_FINDER_MODE="list"
          fi
          continue
          ;;
        ctrl-l)
          if [[ -d $t ]]; then
            {
              ls -dl "$t"
              ls -l "$t"
            } | less
          else
            if type "quickopen" 1>/dev/null 2>/dev/null | grep -q "function"; then
              quickopen "$t"
            else (( $+commands[pygmentize] ));
              get_styles="from pygments.styles import get_all_styles
              styles = list(get_all_styles())
              print('\n'.join(styles))"
              styles=( $(sed -e 's/^  *//g' <<<"$get_styles" | python) )
              style=${${(M)styles:#solarized}:-default}
              export LESSOPEN="| pygmentize -O style=$style -f console256 -g %s"
            fi
            # less +Gg "$t"
          fi
          ;;
        ctrl-d)
          if [[ $CLI_FINDER_DIR == "directory" ]]; then
            CLI_FINDER_DIR="file"
          else
            CLI_FINDER_DIR="directory"
          fi
          continue
          ;;
        ctrl-v)
          vim "$t"
          ;;
        ctrl-c)
          if (( $+commands[pbcopy] )); then
            echo "$t" | tr -d '\n' | pbcopy
          fi
          break
          ;;
        ctrl-i)
          ;;
        *)
          if [ -d $t ]; then
            dir="$t"
            cd "$t"
            continue
          else
            echo "$t"
            break
          fi
          ;;
      esac
    done
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
  ps aux | fzf | awk '{ print \$2 }' | xargs kill -9
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

ghq-update()
{
  ghq list | sed -E 's/^[^\/]+\/(.+)/\1/' | xargs -n 1 -P 10 ghq get -u
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

