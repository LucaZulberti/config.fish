if type -q eza
    alias ls="eza --icons"
    alias l="ls -1"
    alias la="ls -a"
    alias ll="ls -la"
    alias lr="ls -laR"
    alias lt="ls -laT"
    alias lm="ls -la -s modified -r"
    alias lf="ls -f"
    alias lfl="ls -lf"
    alias ld="ls -D"
    alias ldl="ls -lD"
    alias lg="ls -la --git"

    function tree
        lt $extra_flags
    end
end
