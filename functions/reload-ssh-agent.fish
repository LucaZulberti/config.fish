function reload-ssh-agent --description "Reload SSH agent from tmux or ssh"
    if set -q TMUX
        # Prefer tmux environment if available
        set -l sock (tmux show-environment SSH_AUTH_SOCK | string replace 'SSH_AUTH_SOCK=' '')
        if test -n "$sock"
            set -gx SSH_AUTH_SOCK $sock
            echo "SSH_AUTH_SOCK reloaded from tmux: $SSH_AUTH_SOCK"
            return 0
        end
    end


    if set -q SSH_AUTH_SOCK
        echo "SSH_AUTH_SOCK already set: $SSH_AUTH_SOCK"
        return 0
    end


    echo "No SSH agent found"
    return 1
end
