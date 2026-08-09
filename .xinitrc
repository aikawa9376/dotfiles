#!/bin/sh
#
# ~/.xinitrc
#
# Executed by startx (run your window manager from here)

userresources=$HOME/.Xresources
usermodmap=$HOME/.Xmodmap
sysresources=/etc/X11/xinit/.Xresources
sysmodmap=/etc/X11/xinit/.Xmodmap

DEFAULT_SESSION=i3

# merge in defaults and keymaps

if [ -f $sysresources ]; then
    xrdb -merge $sysresources
fi

if [ -f $sysmodmap ]; then
    xmodmap $sysmodmap
fi

if [ -f "$userresources" ]; then
    xrdb -merge "$userresources"
fi

if [ -f "$usermodmap" ]; then
    xmodmap "$usermodmap"
fi

# start some nice programs

if [ -d /etc/X11/xinit/xinitrc.d ] ; then
    for f in /etc/X11/xinit/xinitrc.d/?*.sh ; do
        [ -x "$f" ] && . "$f"
    done
    unset f
fi

get_session(){
	local session_args=()
	case $1 in
		awesome) session_args+=(awesome) ;;
		bspwm) session_args+=(bspwm-session) ;;
		budgie) session_args+=(budgie-desktop) ;;
		cinnamon) session_args+=(cinnamon-session) ;;
		deepin) session_args+=(startdde) ;;
		enlightenment) session_args+=(enlightenment_start) ;;
		fluxbox) session_args+=(startfluxbox) ;;
		gnome) session_args+=(gnome-session) ;;
		i3|i3wm) session_args+=(i3 --shmlog-size 0) ;;
		jwm) session_args+=(jwm) ;;
		kde) session_args+=(startkde) ;;
		lxde) session_args+=(startlxde) ;;
		lxqt) session_args+=(lxqt-session) ;;
		mate) session_args+=(mate-session) ;;
		xfce) session_args+=(xfce4-session) ;;
		openbox) session_args+=(openbox-session) ;;
		*) session_args+=($DEFAULT_SESSION) ;;
	esac

	echo "${session_args[*]}"
}

export DefaultImModule=fcitx
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
export GLFW_IM_MODULE=ibus

xset r rate 150 230

exec $(get_session)
