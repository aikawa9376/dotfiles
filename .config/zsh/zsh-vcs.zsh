# -------------------------------------
# prompt
# -------------------------------------
autoload -Uz vcs_info
autoload -Uz is-at-least
autoload -Uz colors
setopt prompt_subst
setopt combining_chars

zstyle ':vcs_info:git:*' check-for-changes true
zstyle ':vcs_info:git:*' unstagedstr '-'
zstyle ':vcs_info:git:*' stagedstr '+'
zstyle ':vcs_info:*' formats ' (%s:%b)'
zstyle ':vcs_info:*' max-exports 3
zstyle ':vcs_info:*' enable git svn hg bzr
zstyle ':vcs_info:*' actionformats ' (%s:%b)' '%m' '<!%a>'
zstyle ':vcs_info:(svn|bzr):*' branchformat '%b:r%r'
zstyle ':vcs_info:bzr:*' use-simple true

if is-at-least 4.3.10; then
  # git 用のフォーマット
  # git のときはステージしているかどうかを表示
  zstyle ':vcs_info:git:*' formats ' (%s:%b)' '%c%u%m'
  zstyle ':vcs_info:git:*' actionformats ' (%s:%b)' '%c%u%m' '<!%a>'
  zstyle ':vcs_info:git:*' check-for-changes true
fi

# hooks 設定
if is-at-least 4.3.11; then

  function check_master_branch() {
    if [[ `git branch | grep 'master'` =~ 'master' ]] ; then
      echo 'master'
      return
    fi
    echo 'main'
    return
  }

  # git のときはフック関数を設定する

  # formats '(%s)-[%b]' '%c%u %m' , actionformats '(%s)-[%b]' '%c%u %m' '<!%a>'
  # のメッセージを設定する直前のフック関数
  # 今回の設定の場合はformat の時は2つ, actionformats の時は3つメッセージがあるので
  # 各関数が最大3回呼び出される。
  zstyle ':vcs_info:git+set-message:*' hooks \
    git-hook-begin \
    git-untracked \
    git-push-status \
    git-nomerge-branch \
    git-stash-count

  # フックの最初の関数
  # git の作業コピーのあるディレクトリのみフック関数を呼び出すようにする
  # (.git ディレクトリ内にいるときは呼び出さない)
  # .git ディレクトリ内では git status --porcelain などがエラーになるため
  function +vi-git-hook-begin() {
    if [[ $(command git rev-parse --is-inside-work-tree 2> /dev/null) != 'true' ]]; then
      # 0以外を返すとそれ以降のフック関数は呼び出されない
      return 1
    fi

    return 0
  }

  # untracked ファイル表示
  #
  # untracked ファイル(バージョン管理されていないファイル)がある場合は
  # unstaged (%u) に ? を表示
  function +vi-git-untracked() {
    # zstyle formats, actionformats の2番目のメッセージのみ対象にする
    if [[ "$1" != "1" ]]; then
      return 0
    fi

    if command git status --porcelain 2> /dev/null \
      | awk '{print $1}' \
      | command grep -F '??' > /dev/null 2>&1 ; then
        # unstaged (%u) に追加
        hook_com[unstaged]+='?'
    fi
  }

  # push していないコミットの件数表示
  #
  # リモートリポジトリに push していないコミットの件数を
  # pN という形式で misc (%m) に表示する
  function +vi-git-push-status() {
    # zstyle formats, actionformats の2番目のメッセージのみ対象にする
    if [[ "$1" != "1" ]]; then
      return 0
    fi
    local ahead
    # push していないコミット数を取得する
    ahead=$(command git rev-list origin/${hook_com[branch]}..${hook_com[branch]} 2>/dev/null \
      | wc -l \
      | tr -d ' ')
    if [[ "$ahead" -gt 0 ]]; then
      # misc (%m) に追加
      hook_com[misc]+=":p${ahead}"
    fi
  }
  # マージしていない件数表示
  #
  # master 以外のブランチにいる場合に、
  # 現在のブランチ上でまだ master にマージしていないコミットの件数を
  # (mN) という形式で misc (%m) に表示
  function +vi-git-nomerge-branch() {
    local master_branch=`check_master_branch`

    # zstyle formats, actionformats の2番目のメッセージのみ対象にする
    if [[ "$1" != "1" ]]; then
      return 0
    fi

    if [[ "${hook_com[branch]}" == "${master_branch}" ]]; then
      # master ブランチの場合は何もしない
      return 0
    fi

    local nomerged
    nomerged=$(command git rev-list origin/${master_branch}..${hook_com[branch]} 2>/dev/null | wc -l | tr -d ' ')

    if [[ "$nomerged" -gt 0 ]] ; then
      # misc (%m) に追加
      hook_com[misc]+=":m${nomerged}"
    fi
  }

  # stash 件数表示
  #
  # stash している場合は :SN という形式で misc (%m) に表示
  function +vi-git-stash-count() {
    # zstyle formats, actionformats の2番目のメッセージのみ対象にする
    if [[ "$1" != "1" ]]; then
      return 0
    fi

    local stash
    stash=$(command git stash list 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${stash}" -gt 0 ]]; then
      # misc (%m) に追加
      hook_com[misc]+=":S${stash}"
    fi
  }
fi

function _update_vcs_info_msg() {
  local -a messages
  local prompt

  LANG=jp_JP.UTF-8 vcs_info

  # 1行あける
  print
  # バージョン管理されてた場合、ブランチ名
  inside_git_repo="$(git rev-parse --is-inside-work-tree 2>/dev/null)"
  if [ "$inside_git_repo" ]; then
    vcs_info
    psvar=()
    [[ -n "$vcs_info_msg_0_" ]] && messages+=( "%F{green}${vcs_info_msg_0_}%f" )
    [[ -n "$vcs_info_msg_1_" ]] && messages+=( "%F{yellow}${vcs_info_msg_1_}%f" )
    [[ -n "$vcs_info_msg_2_" ]] && messages+=( "%F{red}${vcs_info_msg_2_}%f" )
    local left="%B%F{white}>>%B%F{blue}%~%f%b%B$messages"
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

  print -P $left '\033[38;5;239m'${(r:$padwidth-2::･:)}'\033[0m' $right
}
add-zsh-hook precmd _update_vcs_info_msg
