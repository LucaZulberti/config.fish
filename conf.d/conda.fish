# >>> conda initialize >>>
# !! Contents within this block are managed by 'conda init' !!
if test -f ~/miniconda3/bin/conda
    eval ~/miniconda3/bin/conda "shell.fish" hook $argv | source
else
    if test -f "~/miniconda3/etc/fish/conf.d/conda.fish"
        source "~/miniconda3/etc/fish/conf.d/conda.fish"
    else
        set -gx PATH "~/miniconda3/bin" $PATH
    end
end
# <<< conda initialize <<<

# Always activate base
if type -q conda
    conda activate base
end
