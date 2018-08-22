#!/bin/bash

cd ${HOME}/dotfiles

for f in .??*
do
    [ "$f" == ".git" ] && continue
    [ "$f" == ".DS_Store" ] && continue
    ln -snfv ${HOME}/dotfiles/${f} ${HOME}/${f}
done
