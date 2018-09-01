#!/bin/bash

cd ${HOME}/dotfiles

for f in .??*
do
    [ "$f" == ".git" ] && continue
    [ "$f" == ".DS_Store" ] && continue
    [ "$f" == ".fzf.zsh" ] && continue
    ln -snfv ${HOME}/dotfiles/${f} ${HOME}/${f}
done
