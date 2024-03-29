# -------------------------------------
# エイリアス
# -------------------------------------
case ${OSTYPE} in
  darwin*)
    alias ctags="`brew --prefix`/bin/ctags"
    alias ll='eza -aghHl --color=always --no-quotes --time-style long-iso --sort=modified --reverse --group-directories-first'
    alias ls='gls -GAFh --color=always'
    alias lsg='eza -aghHl --git --color=always --no-quotes --sort=modified --reverse --group-directories-first'
    alias ql='qlmanage -p "$@" >& /dev/null'
    alias awk='gawk'
    alias dircolors='gdircolors'
    ;;
  linux*)
    alias ll='eza -aghHl --color=always --no-quotes --time-style long-iso --sort=modified --reverse --group-directories-first'
    alias ls='ls -GAFltrh --color=always'
    alias lsg='eza -aghHl --git --color=always --no-quotes --sort=modified --reverse --group-directories-first'
    alias chrome='/mnt/c/Program\ Files\ \(x86\)/Google/Chrome/Application/chrome.exe'
    alias photoshop='/mnt/c/Program\ Files/Adobe/Adobe\ Photoshop\ CC\ 2018/Photoshop.exe'
    alias illustrator='/mnt/c/Program\ Files/Adobe/Adobe\ Illustrator\ CC\ 2018/Support\ Files/Contents/Windows/Illustrator.exe'
    alias pdf='/mnt/c/Program\ Files\ \(x86\)/Adobe/Acrobat\ DC/Acrobat/Acrobat.exe'
    alias excel='/mnt/c/Program\ Files/Microsoft\ Office/root/Office16/EXCEL.EXE'
    alias word='/mnt/c/Program\ Files/Microsoft\ Office/root/Office16/WORDICON.EXE'
    alias powerpoint='/mnt/c/Program\ Files/Microsoft\ Office/root/Office16/POWERPNT.EXE'
    alias everything='/mnt/d/apps/Everything/Everything.exe'
    # 定期的にパスが変わる Microsoft App以外からインストールしたほうがよいかも
    alias quicklook='/mnt/c/Program\ Files/WindowsApps/21090PaddyXu.QuickLook_3.6.4.0_neutral__egxr34yet59cg/Package/QuickLook.exe'
    alias ep='explorer.exe `wslpath -w "$PWD"`'
    alias wo='winopen'
    alias q='quickopen'
    alias pdf='okular'
esac

if ((${+commands[nodejs]})); then
  alias node='nodejs'
fi

alias icat='kitty +kitten icat'
alias dst='duster'
alias fnd='finder'
alias li='gwenview ./'
alias reload='exec $SHELL -1'
alias reboot='[ -n $(tmux ls | grep -n "attached") ] && reboot || tmux detach && reboot'
alias suspend="systemctl suspend"
alias vim='nvim'
alias vv='fvim'
alias vs='nvim -S'
alias mutt='neomutt'
alias cp='cp -r'
alias g='gomi'
alias mkdir='mkdir -p'
alias dp='dolphin ./'
alias t='tmuximum'
alias ml='notmuchfzfselect'
alias grk="git log --name-only --oneline | grep -v ' ' | sort | uniq -c | sort -r"
alias pac="paru-selecter"
alias csv="csvfzfviewer"
alias trans="trans -b :ja"
alias feh="feh -d -s"
alias ftpfs="curlftpfs"
alias checkupdate="checkupdates && yay -Qum"
alias virsh="sudo virsh"
alias wup="virtstart"
alias wdown="virtstop"
alias i3wk='ps faux | grep "\_ i3" | head -n 1 | awk "{print \$2}" | xargs kill -s SIGCONT'
alias hs="command history"
alias zsup="abbrev-alias -g bb=''; zinit self-update;abbrev-alias -g bb='| bat'"
alias zup="abbrev-alias -g bb=''; zinit update;abbrev-alias -g bb='| bat'"
alias clp="gpick -o -s -c color_web_hex | xclip -sel c"
alias clpr="gpick -o -s -c color_css_rgb | xclip -sel c"
alias lg="lazygit"

alias cd-="ecd -"
alias cd.="ecd ."
alias cd..="ecd .."

# -------------------------------------
# git
# -------------------------------------
abbrev-alias -g ggs='git status'
abbrev-alias -g gga='git add -u'
abbrev-alias -g ggas='git add -A'
abbrev-alias -g ggc='git commit -m "update"'
abbrev-alias -g ggp='git push'
abbrev-alias -g gl='fshow'
abbrev-alias -g gll='fshow branch'
abbrev-alias -g gf='git fetch'
abbrev-alias -g gm='git merge'
abbrev-alias -g gb='fbr'
abbrev-alias -g gco='git checkout'
# git hub
abbrev-alias -g ghp='gh pr list | fzf --preview "gh pr view {1}; echo -e \"\n\"; gh pr diff --color=always {1}" | awk '\''{print $1}'\'' | xargs gh issue view --web'

# -------------------------------------
# node
# -------------------------------------
alias gulp='npx gulp --no-color'
alias ng='npx ng'
alias clasp='npx clasp'

# -------------------------------------
# php
# -------------------------------------
alias sail='./vendor/bin/sail'

# -------------------------------------
# docker
# -------------------------------------
alias dkp='docker pull'
alias dkc='docker compose'
alias dkr='docker compose run --rm'
alias dkps='docker ps -a'
alias dkri='docker-rmi'
alias dkrm='docker-rm'
alias dkst='docker-stop'
alias dkat='docker-exec-bash'
alias dkk='docker exec'
alias dkur='docker run --rm -v /etc/group:/etc/group:ro -v /etc/passwd:/etc/passwd:ro -u $(id -u $USER):$(id -g $USER)'

# -------------------------------------
# 拡張子 エイリアス
# -------------------------------------
alias -s {gz,tar,zip,msi,rar,7z,rar,xz}='unar' # archives less -> lsar
alias -s {png,jpg,gif}='feh'
alias -s {txt,md}='bat'
# alias -s {pdf}='okular'
alias -s {gddoc,gdscript,gdsheet,gdslides,pptx,pdf,xls,xlsx,doc,docx,ai,psd}='gdopen'

# -------------------------------------
# ディレクトリ エイリアス
# -------------------------------------
function name_dir() # dir, name
{
  local dir=$1
  local name=$2

  if [ -d $dir ]; then
    hash -d $name=$dir
    return 0
  else
    return 1
  fi
}

name_dir /home/aikawa/workspace/ w
name_dir /home/aikawa/gdrive/download/ d

# -------------------------------------
# グローバル エイリアス
# -------------------------------------
setopt extended_glob
zle -N __abbrev_alias::magic_abbrev_expand
zle -N __abbrev_alias::no_magic_abbrev_expand
bindkey " "   __abbrev_alias::magic_abbrev_expand
bindkey "^x " __abbrev_alias::no_magic_abbrev_expand
zle -N __abbrev_alias::magic_abbrev_expand_and_insert
zle -N __abbrev_alias::magic_abbrev_expand_and_accept_line
bindkey " "    __abbrev_alias::magic_abbrev_expand_and_insert
bindkey "^x "  __abbrev_alias::no_magic_abbrev_expand
abbrev-alias -g from='$(mru)'
abbrev-alias -g to='$(destination_directories)'
abbrev-alias -g le='| less'
abbrev-alias -g ff='| fzf --ansi -m'
abbrev-alias -g bb='| bat'
abbrev-alias -g vo='| nvim'
abbrev-alias -g trs="| trans -b :ja"
abbrev-alias -g dst='$(duster)'
abbrev-alias -g fnd='$(finder)'
abbrev-alias -g pyg='"pygmentize -g  {}"'
abbrev-alias -g hh='~/'
