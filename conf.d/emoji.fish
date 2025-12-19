function emoji
    emoji-fzf preview | fzf -m --preview 'emoji-fzf get --name {1}' | cut -d ' ' -f 1 | emoji-fzf get
end
