if type -q zoxide
    # Print the matched directory before navigating to it
    set -gx _ZO_ECHO 1

    # Customize FZF behaviour
    set -gx _ZO_FZF_OPTS \
        --no-sort \
        --bind=ctrl-z:ignore,btab:up,tab:down \
        --cycle \
        --keep-right \
        --border=sharp \
        --height=45% \
        --info=inline \
        --layout=reverse \
        --tabstop=1 \
        --exit-0

    zoxide init fish | source
end
