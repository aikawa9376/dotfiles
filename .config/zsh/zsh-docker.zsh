docker-run() {
  local container
  container="$(docker image ls | sed -e '1d' | fzf --height 40% --reverse --preview-window hidden | awk -v 'OFS=:' '{print $1,$2}')"
  if [ -n "${container}" ]; then
    echo "runing container from ${container} ..."
    docker container run -it --rm ${container}
  fi
}

docker-run-x11() {
  local container
  container="$(docker image ls | sed -e '1d' | fzf --height 40% --reverse --preview-window hidden | awk -v 'OFS=:' '{print $1,$2}')"
  if [ -n "${container}" ]; then
    echo "runing container from ${container} ..."
    xhost +
    docker container run -it --rm \
        -e DISPLAY=$DISPLAY \
        -v /tmp/.X11-unix:/tmp/.X11-unix \
        ${container}
  fi
}

docker-commit() {
  if [ $# -ne 1 ]; then
        echo "指定された引数は$#個です。" 1>&2
        echo "実行するには引数に「イメージ名」が必要です。" 1>&2
        exit 0
    fi

  local container
  container="$(docker container ls -a -f status=running | sed -e '1d' | fzf --height 40% --reverse --preview-window hidden | awk '{print $1}')"
  if [ -n "${container}" ]; then
    echo "committing container to $1 ..."
    docker container commit ${container} $1
  fi
}

docker-copy(){
    if [ $# -ne 1 ]; then
        echo "指定された引数は$#個です。" 1>&2
        echo "実行するには引数に「コピーするソースのパス」が必要です。" 1>&2
        exit 0
    fi

    local container
    container="$(docker container ls -a -f status=running | sed -e '1d' | fzf --height 40% --reverse --preview-window hidden | awk '{print $1}')"
    if [ -n "${container}" ]; then
    echo "moving $1 to container ..."
    docker container cp $1 ${container}:/tmp/
  fi
}

docker-stop() {
  local container
  container="$(docker ps -a -f status=running | sed -e '1d' | fzf --height 40% --reverse --preview-window hidden | awk '{print $1}')"
  if [ -n "${container}" ]; then
    echo 'stopping container...'
    docker stop ${container}
  fi
}

docker-attach() {
  local container
  container="$(docker container ls -a -f status=running | sed -e '1d' | fzf --height 40% --reverse --preview-window hidden | awk '{print $1}')"
  if [ -n "${container}" ]; then
    echo "attaching container ..."
    docker container attach ${container}
  fi
}

docker-rm() {
  local container
  container="$(docker ps -a -f status=exited | sed -e '1d' | fzf --height 40% --reverse --preview-window hidden | awk '{print $1}')"
  if [ -n "${container}" ]; then
    echo 'removing container...'
    docker rm ${container}
  fi
}

docker-rmi() {
  local image
  image="$(docker images -a | sed -e '1d' | fzf --height 40% --reverse --preview-window hidden | awk '{print $3}')"
  if [ -n "${image}" ]; then
    echo 'removing container image...'
    docker rmi ${image}
  fi
}

docker-exec-bash() {
  local container
  container="$(docker ps -a -f status=running | sed -e '1d' | fzf --height 40% --reverse --preview-window hidden | awk '{print $1}')"
  if [ -n "${container}" ]; then
    docker exec -it ${container} /bin/bash
  fi
}
