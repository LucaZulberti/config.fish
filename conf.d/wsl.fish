if test -d /mnt/c/Users
  alias ssh='ssh.exe'
  alias ssh-add='ssh-add.exe'

  # Use windows ssh in Git
  git config --global core.sshCommand ssh.exe
end
