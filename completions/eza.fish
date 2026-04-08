if type -q eza
    set -l cargo_home (set -q CARGO_HOME; and echo $CARGO_HOME; or echo $HOME/.cargo)
    set -l matches $cargo_home/registry/src/*/eza-*/completions/fish/eza.fish

    if test (count $matches) -gt 0
        source (string join \n $matches | sort -V | tail -n 1)
    end
end
