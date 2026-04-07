function __direnv_export
    set -l direnv_bin (command -s direnv 2>/dev/null)

    if test -z "$direnv_bin"
        if test -x /opt/homebrew/bin/direnv
            set direnv_bin /opt/homebrew/bin/direnv
        else
            return
        end
    end

    $direnv_bin export fish | source
end

function __direnv_export_eval --on-event fish_prompt
    __direnv_export

    if test "$direnv_fish_mode" != "disable_arrow"
        function __direnv_cd_hook --on-variable PWD
            if test "$direnv_fish_mode" = "eval_after_arrow"
                set -g __direnv_export_again 0
            else
                __direnv_export
            end
        end
    end
end

function __direnv_export_eval_2 --on-event fish_preexec
    if set -q __direnv_export_again
        set -e __direnv_export_again
        __direnv_export
        echo
    end

    functions --erase __direnv_cd_hook
end
