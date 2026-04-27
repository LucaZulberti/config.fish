if type -q npm
    set -gx NODE_MODULES_GLOBAL "$(npm root -g)"
end

if type -q hx
    set -gx EDITOR hx
end
