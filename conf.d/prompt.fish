# Override 'prompt_hostname'
function prompt_hostname --description 'short hostname for the prompt'
    # First letter uppercase anyway
    set capitalized (string upper (string sub -l 1 $hostname))(string sub -s 2 $hostname) 

    # Keep only capitalized letters in hostname
    string match -ar '[A-Z]+' $capitalized | string join ''
end

# Check if inside a tmux session
if set -q TMUX
    # Override the prompt
    function fish_prompt
        # Inside tmux: Add a custom indicator and skip original fish prompt
        set_color cyan
        echo -n "🐟 > "
    end
end
