# 1Password completion
op completion fish | source

# 1Password SSH Agent
if test -z "$SSH_TTY"
  set -x SSH_AUTH_SOCK ~/.1password/agent.sock
end
