# Override 'prompt_hostname'
function prompt_hostname --description 'short hostname for the prompt'
    # First letter uppercase anyway
    set capitalized (string upper (string sub -l 1 $hostname))(string sub -s 2 $hostname) 

    # Keep only capitalized letters in hostname
    string match -ar '[A-Z]+' $capitalized | string join ''
end

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
