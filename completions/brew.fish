if type -q brew
    if test -d (brew --prefix)"/share/fish/completions"
        set -gp fish_complete_path (brew --prefix)/share/fish/completions
    end

    if test -d (brew --prefix)"/share/fish/vendor_completions.d"
        set -gp fish_complete_path (brew --prefix)/share/fish/vendor_completions.d
    end
end
