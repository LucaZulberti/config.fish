# 1Password completion
if type -q op
  op completion fish | source
end

# If SSH Agent is not set or is using macOS Launchd socket...
if not set -q SSH_AUTH_SOCK || string match -q "/private/tmp/com.apple.launchd.*" $SSH_AUTH_SOCK
  # Use 1Password SSH Agent if available
  if test -S ~/.1password/agent.sock
    set -x SSH_AUTH_SOCK ~/.1password/agent.sock
  else if test -S ~/Library/Group\ Containers/2BUA8C4S2C.com.1password/ssh-agent.sock
    set -x SSH_AUTH_SOCK ~/Library/Group\ Containers/2BUA8C4S2C.com.1password/ssh-agent.sock
  end
end

# Ensure ~/.agent.sock always links to the active SSH_AUTH_SOCK
if set -q SSH_AUTH_SOCK
  ln -sf $SSH_AUTH_SOCK ~/.agent.sock
else
  rm -f ~/.agent.sock
end
