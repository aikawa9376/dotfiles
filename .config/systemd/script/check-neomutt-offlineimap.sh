#!/bin/zsh
if [[ $(ps faux | grep neomutt | grep -v grep | wc -l)  == 3 ]]; then /usr/bin/offlineimap -f INBOX -o -q -k Account_GMail:postsynchook= -u quiet; fi
