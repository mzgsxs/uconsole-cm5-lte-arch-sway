[[ -f ~/.bashrc ]] && . ~/.bashrc

# Launch sway on the physical console only; SSH sessions get a plain shell.
if [[ -z $WAYLAND_DISPLAY && $XDG_VTNR == 1 ]]; then
    # Force software cursors. The DRM hardware cursor plane on this panel leaves
    # pixel residue at the screen edge; software cursors cost a little CPU and
    # render correctly. wlroots in this build still honours this variable.
    export WLR_NO_HARDWARE_CURSORS=1
    exec sway
fi
