# Check if inside a tmux session
if set -q TMUX
    # Inside tmux: Add a custom indicator and skip original fish prompt

    # Override the fish prompt
    function fish_prompt
        # Capture the return value
        set return_value $status
        
        set_color cyan
        echo -n "🐟 "
        
        # Print the prompt
        if test $return_value -ne 0
            set_color red
            echo -n "[$return_value] "
        end
            
        set_color cyan
        echo -n "> "
    end
end
