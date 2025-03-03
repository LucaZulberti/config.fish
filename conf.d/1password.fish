# 1Password completion
if type -q op
  op completion fish | source
end

# 1Password SSH Agent
if not set -q SSH_AUTH_SOCK
  if test -S ~/.1password/agent.sock
    ln -sf ~/.1password/agent.sock ~/.agent.sock
    set -x SSH_AUTH_SOCK ~/.agent.sock
  end
else
  ln -sf "$SSH_AUTH_SOCK" ~/.agent.sock
end
