#!/bin/bash

for f in .??*
do
    [ "$f" == ".git" ] && continue
    [ "$f" == ".DS_Store" ] && continue
    ln -snfv ${HOME}/dotfiles/${f} ${HOME}/${f}
    echo "ln -snfv ${f} ${HOME}/${f}"
done
