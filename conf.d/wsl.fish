if test -d /mnt/c/Users
  alias ssh='ssh.exe'
  alias ssh-add='ssh-add.exe'
  alias scp='scp.exe'

  # Use windows ssh in Git
  git config --global core.sshCommand ssh.exe

  # Copy .ssh from Windows link, if present
  if test -s ~/.ssh_win
    rm -rf ~/.ssh
    cp -rL ~/.ssh_win ~/.ssh
    chmod -R 600 ~/.ssh/*
    chmod    700 ~/.ssh
  end
end
