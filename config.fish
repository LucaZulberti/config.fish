if status is-interactive
    # Commands to run in interactive sessions can go here

    # Set time zone
    set -x TZ (readlink /etc/localtime | sed 's|.*/zoneinfo/||')
end

