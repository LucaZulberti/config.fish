if test -d /opt/homebrew
    /opt/homebrew/bin/brew shellenv fish | source
else if test -d /home/linuxbrew/.linuxbrew
    /home/linuxbrew/.linuxbrew/bin/brew shellenv fish | source
end
