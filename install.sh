#!/bin/bash
cd ${HOME}
curl -sL --proto-redir -all,https https://raw.githubusercontent.com/zplug/installer/master/installer.zsh| zsh

cd ${HOME}/dotfiles

for f in .??*
do
    [ "$f" == ".git" ] && continue
    [ "$f" == ".DS_Store" ] && continue
    ln -snfv ${HOME}/dotfiles/${f} ${HOME}/${f}
done
