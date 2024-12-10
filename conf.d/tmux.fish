alias tmuxs "~/.config/tmux/scripts/tmux-sessionizer-tmuxp"

# Link tmuxp sessions to tmuxp directory
[ ! -e ~/.tmuxp ] && ln -s ~/.config/tmux/sessions ~/.tmuxp
