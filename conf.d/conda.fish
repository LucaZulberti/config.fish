# >>> conda initialize >>>
# !! Contents within this block are managed by 'conda init' !!
if test -f /Users/luca/miniconda3/bin/conda
    eval /Users/luca/miniconda3/bin/conda "shell.fish" "hook" $argv | source
else
    if test -f "/Users/luca/miniconda3/etc/fish/conf.d/conda.fish"
        . "/Users/luca/miniconda3/etc/fish/conf.d/conda.fish"
    else
        set -x PATH "/Users/luca/miniconda3/bin" $PATH
    end
end
# <<< conda initialize <<<

# Always activate base
if type -q conda
  conda activate base
end
