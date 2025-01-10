# 1Password completion
if type -q op
  op completion fish | source
end

# 1Password SSH Agent
if test -z "$SSH_TTY"
  set -x SSH_AUTH_SOCK ~/.1password/agent.sock
end
