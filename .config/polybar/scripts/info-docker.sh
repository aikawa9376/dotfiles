#! /bin/sh

isDocker=$(docker ps -q | wc -l)

if [[ $isDocker -gt 0 ]]; then
  echo $isDocker
else
  echo ""
fi
