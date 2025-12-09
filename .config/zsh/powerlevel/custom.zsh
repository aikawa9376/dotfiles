# User-defined prompt segments can be customized the same way as built-in segments.
typeset -g POWERLEVEL9K_EXAMPLE_FOREGROUND=3
typeset -g POWERLEVEL9K_EXAMPLE_BACKGROUND=1
# typeset -g POWERLEVEL9K_EXAMPLE_VISUAL_IDENTIFIER_EXPANSION='⭐'

# ---------------------[ Custom Segments ]---------------------
### user ###
# typeset -g POWERLEVEL9K_USER_{LEFT,RIGHT}_SUBSEGMENT_SEPARATOR=''

function prompt_user() {
  # アイコンや色を自由にカスタマイズできます
  local user_icon='' # Font Awesomeのuserアイコン (U+F007)
  local user_color='244' # グレー

  # p10k segmentコマンドでセグメントの内容を定義
  # %n はzshで「ユーザー名」を意味する特別な文字列です
  p10k segment -f "$user_color" -i "$user_icon" -t "%n"
}

### host ###
function prompt_host() {
  # ★★★ SSH接続中のみホスト名を表示する設定 ★★★
  # [[ -n "$SSH_CLIENT" ]] || return

  # アイコンや色を自由にカスタマイズ
  local host_icon=''  # Font Awesomeのdesktopアイコン (U+F109)
  local host_color='244' # グレー

  # %m はzshで「ホスト名」を意味する特別な文字列です
  p10k segment -f "$host_color" -i "$host_icon" -t "%m"
}

### dokcer ###
typeset -g POWERLEVEL9K_DOCKER_FOREGROUND=blue
function prompt_docker() {
  # Dockerアイコンと色を設定
  local docker_icon=''
  local docker_color='33'

  # Dockerコンテナ数を取得（awkで余分な空白なし）
  local container_count=$(docker compose ps -q 2>/dev/null | awk 'END{print NR}')

  # コンテナ数が取得できない場合は何も表示しない
  [[ -z "$container_count" || "$container_count" -eq 0 ]] && return

  # p10kセグメントを定義
  p10k segment -f "$docker_color" -i "$docker_icon" -t "$container_count"
}
