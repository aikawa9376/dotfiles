# -------------------------------------
# エイリアス
# -------------------------------------
case ${OSTYPE} in
  darwin*)
    alias ctags="`brew --prefix`/bin/ctags"
    alias ll='exa -aghHl --color=auto --time-style long-iso --sort=modified --reverse --group-directories-first'
    alias ls='gls -GAFh --color=auto'
    alias lsg='exa -aghHl --git --color=auto --sort=modified --reverse --group-directories-first'
    alias ql='qlmanage -p "$@" >& /dev/null'
    alias awk='gawk'
    alias dircolors='gdircolors'
    ;;
  linux*)
    alias ll='exa -aghHl --color=auto --time-style long-iso --sort=modified --reverse --group-directories-first'
    alias ls='ls -GAFltrh --color=auto'
    alias lsg='exa -aghHl --git --color=auto --sort=modified --reverse --group-directories-first'
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

alias rcat='richpager -n'
alias dst='duster'
alias fnd='finder'
alias reload='exec $SHELL -1'
alias -g from='$(mru)'
alias -g to='$(destination_directories)'
alias -g le='| less'
alias -g ff='| fzf'
alias -g dust='$(duster)'
alias -g fnd='$(finder)'
alias -g pyg='"pygmentize -g  {}"'
alias vim='nvim'
alias cp='cp -r'
alias t='tmuximum'
alias grk="git log --name-only --oneline | grep -v ' ' | sort | uniq -c | sort -r"

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

name_dir /mnt/d/workspace/ w
name_dir /home/aikawa/Desktop/ d
name_dir /mnt/c/Users/aikaw/Desktop/ d
name_dir /home/aikawa/Downloads/ dl
name_dir /mnt/c/Users/aikaw/Downloads/ dl
