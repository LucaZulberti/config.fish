# Colorls installed with Ruby: gem install colorls

# Use colorls with fish shell
alias ls="colorls --dark"
alias l="colorls --dark --sd"
alias la="colorls --dark -A --sd"
alias ll="colorls --dark -lA --sd"
alias lf="colorls --dark -f"
alias ld="colorls --dark -d"
alias lt="colorls --dark -lAt"
alias lg="colorls --dark -lA --sd --gs"

function tree
    # Parse arguments
    for arg in $argv
        if set match (string match -r -- '^(-L)([0-9]+)$' $arg)
          set depth_flag "="(string sub -s 3 -- $arg)
        else
          # Collect any additional flags or arguments
          set extra_flags (string trim -- $extra_flags $arg)
        end
    end

    # Construct and execute the colorls command
    colorls --dark --tree$depth_flag $extra_flags
end
