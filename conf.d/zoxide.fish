if type -q zoxide
  # Print the matched directory before navigating to it
  set -gx _ZO_ECHO 1

  zoxide init fish | source
end
