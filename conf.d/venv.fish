if ! test -d $HOME/miniconda3
    if test -d $HOME/.venv/work
        source $HOME/.venv/work/bin/activate.fish
    end
end
