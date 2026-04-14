# =========================================================
# 🍅 Pomodoro Timer — Fish frontend
#
# Fish is intentionally kept as a thin CLI frontend only.
# The long-running timer must be supervised by a real service manager:
#   - Linux:  systemd --user
#   - macOS:  launchd LaunchAgent
#
# This avoids the usual "daemonize from shell" problems:
#   - child process tied to the TTY/session
#   - fragile PID tracking
#   - different environment between interactive and non-interactive shells
#   - background jobs dying at logout
#
# Optional override:
#   set -gx POMODORO_DAEMON_PATH ~/.config/fish/bin/pomodoro.fish
#
# Optional configuration defaults:
#   set -gx POMODORO_WORK_MIN 25
#   set -gx POMODORO_SHORT_BREAK_MIN 5
#   set -gx POMODORO_LONG_BREAK_MIN 15
#   set -gx POMODORO_CYCLE_POMODOROS 4
# =========================================================

function __pomodoro_state_dir --description 'Return the directory used for persistent timer state'
    if set -q XDG_STATE_HOME; and test -n "$XDG_STATE_HOME"
        echo "$XDG_STATE_HOME/pomodoro"
    else
        echo ~/.local/state/pomodoro
    end
end

function __pomodoro_pidfile --description 'Return the PID file path for manual daemon tracking'
    echo (__pomodoro_state_dir)/pid
end

function __pomodoro_statefile --description 'Return the state file path for the active Pomodoro session'
    echo (__pomodoro_state_dir)/state
end

function __pomodoro_daemon_path --description 'Return the standalone daemon path, honoring user override'
    if set -q POMODORO_DAEMON_PATH; and test -n "$POMODORO_DAEMON_PATH"
        echo "$POMODORO_DAEMON_PATH"
    else
        echo ~/.config/fish/bin/pomodoro.fish
    end
end

function __pomodoro_systemd_unit_name --description 'Return the systemd user unit name'
    echo pomodoro.service
end

function __pomodoro_systemd_unit_path --description 'Return the expected path of the systemd user unit file'
    echo ~/.config/systemd/user/(__pomodoro_systemd_unit_name)
end

function __pomodoro_launchd_label --description 'Return the launchd label used on macOS'
    echo com.$USER.pomodoro
end

function __pomodoro_launchd_plist_path --description 'Return the expected path of the LaunchAgent plist'
    echo ~/Library/LaunchAgents/(__pomodoro_launchd_label).plist
end

function __pomodoro_default_work_min --description 'Return default work duration in minutes'
    if set -q POMODORO_WORK_MIN; and test -n "$POMODORO_WORK_MIN"
        echo "$POMODORO_WORK_MIN"
    else
        echo 25
    end
end

function __pomodoro_default_short_break_min --description 'Return default short-break duration in minutes'
    if set -q POMODORO_SHORT_BREAK_MIN; and test -n "$POMODORO_SHORT_BREAK_MIN"
        echo "$POMODORO_SHORT_BREAK_MIN"
    else
        echo 5
    end
end

function __pomodoro_default_long_break_min --description 'Return default long-break duration in minutes'
    if set -q POMODORO_LONG_BREAK_MIN; and test -n "$POMODORO_LONG_BREAK_MIN"
        echo "$POMODORO_LONG_BREAK_MIN"
    else
        echo 15
    end
end

function __pomodoro_default_cycle_pomodoros --description 'Return default number of work sessions per cycle'
    if set -q POMODORO_CYCLE_POMODOROS; and test -n "$POMODORO_CYCLE_POMODOROS"
        echo "$POMODORO_CYCLE_POMODOROS"
    else
        echo 4
    end
end

function __pomodoro_write_state --description 'Atomically rewrite the session state file'
    set -l run_state $argv[1]
    set -l mode_name $argv[2]
    set -l end_epoch $argv[3]
    set -l remaining_sec $argv[4]
    set -l work_min $argv[5]
    set -l short_break_min $argv[6]
    set -l long_break_min $argv[7]
    set -l cycle_pomodoros $argv[8]
    set -l pomodoro_index $argv[9]

    set -l state_dir (__pomodoro_state_dir)
    set -l statefile (__pomodoro_statefile)
    set -l tmpfile "$statefile.tmp"

    mkdir -p "$state_dir"

    # Write to a temporary file first, then rename atomically.
    # This avoids partial state if the shell is interrupted while writing.
    printf "%s\n" \
        "set run_state $run_state" \
        "set mode $mode_name" \
        "set end $end_epoch" \
        "set remaining $remaining_sec" \
        "set work $work_min" \
        "set short_break $short_break_min" \
        "set long_break $long_break_min" \
        "set cycle_pomodoros $cycle_pomodoros" \
        "set pomodoro_index $pomodoro_index" >"$tmpfile"

    mv -f "$tmpfile" "$statefile"
end

function __pomodoro_validate_positive_int --description 'Validate that a value is a positive integer'
    set -l label $argv[1]
    set -l value $argv[2]

    if not string match -qr '^[1-9][0-9]*$' -- "$value"
        echo "error: $label must be a positive integer (got: '$value')" >&2
        return 1
    end
end

function __pomodoro_validate_uint --description 'Validate that a value is a non-negative integer'
    set -l label $argv[1]
    set -l value $argv[2]

    if not string match -qr '^[0-9]+$' -- "$value"
        echo "error: state field '$label' must be a non-negative integer (got: '$value')" >&2
        return 1
    end
end

function __pomodoro_read_state --description 'Read and validate the persisted Pomodoro state, then print it as 9 lines'
    set -l statefile (__pomodoro_statefile)

    if not test -f "$statefile"
        return 1
    end

    # The state file is written by this script in Fish syntax on purpose, so it
    # can be sourced without a custom parser.
    source "$statefile"

    if not set -q run_state
        echo "error: malformed state file: missing run_state" >&2
        return 1
    end
    if not set -q mode
        echo "error: malformed state file: missing mode" >&2
        return 1
    end
    if not set -q end
        echo "error: malformed state file: missing end" >&2
        return 1
    end
    if not set -q remaining
        echo "error: malformed state file: missing remaining" >&2
        return 1
    end
    if not set -q work
        echo "error: malformed state file: missing work" >&2
        return 1
    end
    if not set -q short_break
        echo "error: malformed state file: missing short_break" >&2
        return 1
    end
    if not set -q long_break
        echo "error: malformed state file: missing long_break" >&2
        return 1
    end
    if not set -q cycle_pomodoros
        echo "error: malformed state file: missing cycle_pomodoros" >&2
        return 1
    end
    if not set -q pomodoro_index
        echo "error: malformed state file: missing pomodoro_index" >&2
        return 1
    end

    switch "$run_state"
        case running paused
        case '*'
            echo "error: malformed state file: invalid run_state '$run_state'" >&2
            return 1
    end

    switch "$mode"
        case work short_break long_break
        case '*'
            echo "error: malformed state file: invalid mode '$mode'" >&2
            return 1
    end

    __pomodoro_validate_uint end "$end"; or return 1
    __pomodoro_validate_uint remaining "$remaining"; or return 1
    __pomodoro_validate_positive_int work "$work"; or return 1
    __pomodoro_validate_positive_int short_break "$short_break"; or return 1
    __pomodoro_validate_positive_int long_break "$long_break"; or return 1
    __pomodoro_validate_positive_int cycle_pomodoros "$cycle_pomodoros"; or return 1
    __pomodoro_validate_positive_int pomodoro_index "$pomodoro_index"; or return 1

    printf "%s\n" \
        "$run_state" \
        "$mode" \
        "$end" \
        "$remaining" \
        "$work" \
        "$short_break" \
        "$long_break" \
        "$cycle_pomodoros" \
        "$pomodoro_index"
end

function __pomodoro_detect_backend --description 'Detect which execution backend is available on this host'
    switch (uname)
        case Linux
            if command -q systemctl; and test -f (__pomodoro_systemd_unit_path)
                echo systemd
                return 0
            end

        case Darwin
            if command -q launchctl; and test -f (__pomodoro_launchd_plist_path)
                echo launchd
                return 0
            end
    end

    # "manual" is only a fallback for debugging.
    echo manual
end

function __pomodoro_is_manual_daemon_running --description 'Check whether a manually started daemon is still alive'
    set -l pidfile (__pomodoro_pidfile)

    if not test -f "$pidfile"
        return 1
    end

    set -l pid (cat "$pidfile" 2>/dev/null)
    test -n "$pid"; and kill -0 "$pid" 2>/dev/null
end

function __pomodoro_ensure_running --description 'Ensure that the daemon is running through the selected backend'
    switch (__pomodoro_detect_backend)
        case systemd
            systemctl --user daemon-reload

            if not systemctl --user is-active --quiet (__pomodoro_systemd_unit_name)
                systemctl --user start (__pomodoro_systemd_unit_name)
            end

        case launchd
            set -l uid (id -u)
            set -l label (__pomodoro_launchd_label)
            set -l plist (__pomodoro_launchd_plist_path)

            if launchctl print gui/$uid/$label >/dev/null 2>&1
                launchctl kickstart -k gui/$uid/$label >/dev/null 2>&1
            else
                launchctl bootstrap gui/$uid "$plist"
            end

        case manual
            if __pomodoro_is_manual_daemon_running
                return 0
            end

            echo "error: no service manager file installed." >&2
            echo "       install one of these first:" >&2
            echo "       - Linux:   ~/.config/systemd/user/pomodoro.service" >&2
            echo "       - macOS:   ~/Library/LaunchAgents/com.$USER.pomodoro.plist" >&2
            echo "       For debugging only, run the daemon manually in another shell:" >&2
            echo "       "(__pomodoro_daemon_path) >&2
            return 1
    end
end

function __pomodoro_stop_manual_backend --description 'Stop a manually started daemon using its PID file'
    set -l pidfile (__pomodoro_pidfile)

    if test -f "$pidfile"
        set -l pid (cat "$pidfile" 2>/dev/null)

        if test -n "$pid"; and kill -0 "$pid" 2>/dev/null
            kill "$pid" 2>/dev/null
        end

        rm -f "$pidfile"
    end
end

function __pomodoro_interrupt_backend --description 'Fully stop the backend process or service'
    switch (__pomodoro_detect_backend)
        case systemd
            systemctl --user stop (__pomodoro_systemd_unit_name) >/dev/null 2>&1

        case launchd
            set -l uid (id -u)
            set -l label (__pomodoro_launchd_label)
            set -l plist (__pomodoro_launchd_plist_path)

            if launchctl print gui/$uid/$label >/dev/null 2>&1
                launchctl bootout gui/$uid "$plist" >/dev/null 2>&1
            end

        case manual
            __pomodoro_stop_manual_backend >/dev/null 2>&1
    end
end

function __pomodoro_phase_label --description 'Return a human-readable label for the current phase'
    switch "$argv[1]"
        case work
            echo work
        case short_break
            echo "short break"
        case long_break
            echo "long break"
    end
end

function __pomodoro_position_label --description 'Return the cycle position label for the current phase'
    set -l mode $argv[1]
    set -l pomodoro_index $argv[2]
    set -l cycle_pomodoros $argv[3]

    switch "$mode"
        case work
            echo "pomodoro $pomodoro_index/$cycle_pomodoros"
        case short_break long_break
            echo "after pomodoro $pomodoro_index/$cycle_pomodoros"
    end
end

function __pomodoro_next_label --description 'Return a human-readable label for the next phase'
    set -l mode $argv[1]
    set -l pomodoro_index $argv[2]
    set -l cycle_pomodoros $argv[3]

    switch "$mode"
        case work
            if test "$pomodoro_index" -ge "$cycle_pomodoros"
                echo "long break"
            else
                echo "short break"
            end

        case short_break
            set -l next_index (math "$pomodoro_index + 1")
            echo "work $next_index/$cycle_pomodoros"

        case long_break
            echo "work 1/$cycle_pomodoros"
    end
end

function __pomodoro_start --description 'Start a new session or resume a paused one'
    set -l state (__pomodoro_read_state 2>/dev/null)
    set -l state_status $status

    # Resume only when:
    # - no explicit arguments were provided
    # - a valid state exists
    # - the session is paused
    if test (count $argv) -eq 0; and test $state_status -eq 0; and test "$state[1]" = paused
        set -l mode $state[2]
        set -l remaining $state[4]
        set -l work $state[5]
        set -l short_break $state[6]
        set -l long_break $state[7]
        set -l cycle_pomodoros $state[8]
        set -l pomodoro_index $state[9]

        set -l now_epoch (date +%s)
        set -l end_epoch (math "$now_epoch + $remaining")

        __pomodoro_write_state running "$mode" "$end_epoch" 0 "$work" "$short_break" "$long_break" "$cycle_pomodoros" "$pomodoro_index"

        if not __pomodoro_ensure_running
            __pomodoro_write_state paused "$mode" 0 "$remaining" "$work" "$short_break" "$long_break" "$cycle_pomodoros" "$pomodoro_index"
            return 1
        end

        echo "▶ Resumed — "(__pomodoro_phase_label "$mode")" | "(__pomodoro_position_label "$mode" "$pomodoro_index" "$cycle_pomodoros")
        return 0
    end

    # If already running and no arguments were provided, keep behavior non-destructive.
    if test (count $argv) -eq 0; and test $state_status -eq 0; and test "$state[1]" = running
        __pomodoro_status
        return 0
    end

    set -l work_min $argv[1]
    set -l short_break_min $argv[2]
    set -l long_break_min $argv[3]
    set -l cycle_pomodoros $argv[4]

    if test -z "$work_min"
        set work_min (__pomodoro_default_work_min)
    end
    if test -z "$short_break_min"
        set short_break_min (__pomodoro_default_short_break_min)
    end
    if test -z "$long_break_min"
        set long_break_min (__pomodoro_default_long_break_min)
    end
    if test -z "$cycle_pomodoros"
        set cycle_pomodoros (__pomodoro_default_cycle_pomodoros)
    end

    __pomodoro_validate_positive_int work "$work_min"; or return 1
    __pomodoro_validate_positive_int short_break "$short_break_min"; or return 1
    __pomodoro_validate_positive_int long_break "$long_break_min"; or return 1
    __pomodoro_validate_positive_int cycle_pomodoros "$cycle_pomodoros"; or return 1

    set -l now_epoch (date +%s)
    set -l end_epoch (math "$now_epoch + $work_min * 60")

    __pomodoro_write_state running work "$end_epoch" 0 "$work_min" "$short_break_min" "$long_break_min" "$cycle_pomodoros" 1

    if not __pomodoro_ensure_running
        rm -f (__pomodoro_statefile)
        return 1
    end

    echo "🍅 Started — work $work_min min | short $short_break_min min | long $long_break_min min | cycle $cycle_pomodoros"
end

function __pomodoro_stop --description 'Pause the current session without clearing it'
    set -l state (__pomodoro_read_state 2>/dev/null)
    set -l state_status $status

    if test $state_status -ne 0
        echo "No active session"
        return 0
    end

    set -l run_state $state[1]
    set -l mode $state[2]
    set -l end $state[3]
    set -l remaining $state[4]
    set -l work $state[5]
    set -l short_break $state[6]
    set -l long_break $state[7]
    set -l cycle_pomodoros $state[8]
    set -l pomodoro_index $state[9]

    if test "$run_state" = paused
        echo "⏸  Already paused"
        return 0
    end

    set -l now_epoch (date +%s)
    set -l remaining_sec (math "$end - $now_epoch")
    if test "$remaining_sec" -lt 0
        set remaining_sec 0
    end

    __pomodoro_write_state paused "$mode" 0 "$remaining_sec" "$work" "$short_break" "$long_break" "$cycle_pomodoros" "$pomodoro_index"
    echo "⏸ Paused — "(__pomodoro_phase_label "$mode")" | "(__pomodoro_position_label "$mode" "$pomodoro_index" "$cycle_pomodoros")
end

function __pomodoro_reset --description 'Restart from pomodoro 1 using either current or provided configuration'
    set -l existing_state (__pomodoro_read_state 2>/dev/null)
    set -l existing_state_status $status

    set -l work_min $argv[1]
    set -l short_break_min $argv[2]
    set -l long_break_min $argv[3]
    set -l cycle_pomodoros $argv[4]

    if test -z "$work_min"
        if test $existing_state_status -eq 0
            set work_min $existing_state[5]
        else
            set work_min (__pomodoro_default_work_min)
        end
    end

    if test -z "$short_break_min"
        if test $existing_state_status -eq 0
            set short_break_min $existing_state[6]
        else
            set short_break_min (__pomodoro_default_short_break_min)
        end
    end

    if test -z "$long_break_min"
        if test $existing_state_status -eq 0
            set long_break_min $existing_state[7]
        else
            set long_break_min (__pomodoro_default_long_break_min)
        end
    end

    if test -z "$cycle_pomodoros"
        if test $existing_state_status -eq 0
            set cycle_pomodoros $existing_state[8]
        else
            set cycle_pomodoros (__pomodoro_default_cycle_pomodoros)
        end
    end

    __pomodoro_validate_positive_int work "$work_min"; or return 1
    __pomodoro_validate_positive_int short_break "$short_break_min"; or return 1
    __pomodoro_validate_positive_int long_break "$long_break_min"; or return 1
    __pomodoro_validate_positive_int cycle_pomodoros "$cycle_pomodoros"; or return 1

    set -l now_epoch (date +%s)
    set -l end_epoch (math "$now_epoch + $work_min * 60")

    __pomodoro_write_state running work "$end_epoch" 0 "$work_min" "$short_break_min" "$long_break_min" "$cycle_pomodoros" 1

    if not __pomodoro_ensure_running
        rm -f (__pomodoro_statefile)
        return 1
    end

    echo "🔄 Reset — restarted from pomodoro 1/$cycle_pomodoros"
end

function __pomodoro_clear --description 'Fully interrupt the current session and remove all persisted Pomodoro state'
    # "clear" is intentionally stronger than:
    # - stop: pause and keep the session resumable
    # - reset: restart from the first pomodoro of the cycle
    #
    # Here we want a hard interruption: backend stopped, state removed,
    # no future resume possible.
    __pomodoro_interrupt_backend
    rm -rf -- (__pomodoro_state_dir)
    echo "🧹 Cleared — session interrupted and state removed"
end

function __pomodoro_use_color --description 'Return success if colored output should be used'
    if not isatty stdout
        return 1
    end

    if set -q NO_COLOR
        return 1
    end

    return 0
end

function __pomodoro_paint --description 'Print text with color when enabled'
    set -l color_name $argv[1]
    set -l text $argv[2..-1]

    if __pomodoro_use_color
        printf "%s%s%s" (set_color $color_name) "$text" (set_color normal)
    else
        printf "%s" "$text"
    end
end

function __pomodoro_format_remaining --description 'Format seconds as M:SS'
    set -l total_sec $argv[1]
    set -l mins (math -s0 "$total_sec / 60")
    set -l secs (math "$total_sec % 60")
    printf "%d:%02d" "$mins" "$secs"
end

function __pomodoro_run_state_icon --description 'Return an icon for run state'
    switch "$argv[1]"
        case running
            echo "▶"
        case paused
            echo "⏸"
        case '*'
            echo "•"
    end
end

function __pomodoro_mode_icon --description 'Return an icon for the current phase'
    switch "$argv[1]"
        case work
            echo "🍅"
        case short_break
            echo "☕"
        case long_break
            echo "🌴"
        case '*'
            echo "•"
    end
end

function __pomodoro_run_state_color --description 'Return the preferred color for run state'
    switch "$argv[1]"
        case running
            echo green
        case paused
            echo yellow
        case '*'
            echo normal
    end
end

function __pomodoro_mode_color --description 'Return the preferred color for the current phase'
    switch "$argv[1]"
        case work
            echo red
        case short_break
            echo cyan
        case long_break
            echo magenta
        case '*'
            echo normal
    end
end

function __pomodoro_status --description 'Show detailed session status with icons and colors'
    set -l state (__pomodoro_read_state 2>/dev/null)
    set -l state_status $status

    if test $state_status -ne 0
        printf "%s %s\n" \
            (__pomodoro_paint brblack "○ ") \
            (__pomodoro_paint brblack "No active session")
        return 0
    end

    set -l run_state $state[1]
    set -l mode $state[2]
    set -l end $state[3]
    set -l remaining $state[4]
    set -l work $state[5]
    set -l short_break $state[6]
    set -l long_break $state[7]
    set -l cycle_pomodoros $state[8]
    set -l pomodoro_index $state[9]

    set -l remaining_sec 0
    if test "$run_state" = paused
        set remaining_sec $remaining
    else
        set -l now_epoch (date +%s)
        set remaining_sec (math "$end - $now_epoch")
        if test "$remaining_sec" -lt 0
            set remaining_sec 0
        end
    end

    set -l phase_label (__pomodoro_phase_label "$mode")
    set -l position_label (__pomodoro_position_label "$mode" "$pomodoro_index" "$cycle_pomodoros")
    set -l next_label (__pomodoro_next_label "$mode" "$pomodoro_index" "$cycle_pomodoros")
    set -l remaining_label (__pomodoro_format_remaining "$remaining_sec")

    set -l run_icon (__pomodoro_run_state_icon "$run_state")
    set -l mode_icon (__pomodoro_mode_icon "$mode")
    set -l run_color (__pomodoro_run_state_color "$run_state")
    set -l mode_color (__pomodoro_mode_color "$mode")

    printf "%s %s  %s %s  %s  %s %s\n" \
        (__pomodoro_paint "$run_color" "$run_icon") \
        (__pomodoro_paint "$run_color" (string upper "$run_state")) \
        (__pomodoro_paint "$mode_color" "$mode_icon") \
        (__pomodoro_paint "$mode_color" (string upper "$phase_label")) \
        (__pomodoro_paint blue "$position_label") \
        (__pomodoro_paint brwhite "$remaining_label") \
        (__pomodoro_paint brblack "remaining")

    printf "%s %s  %s %s  %s %s\n" \
        (__pomodoro_paint brblack " ↳") \
        (__pomodoro_paint brblack " next:   ") \
        (__pomodoro_paint cyan (string upper "$next_label"))

    printf "%s %s\n  - %s %s min\n  - %s %s min\n  - %s %s min\n  - %s %s\n" \
        (__pomodoro_paint brblack "⚙ ") \
        (__pomodoro_paint brblack "config") \
        (__pomodoro_paint red "work") \
        (__pomodoro_paint red "$work") \
        (__pomodoro_paint cyan "short") \
        (__pomodoro_paint cyan "$short_break") \
        (__pomodoro_paint magenta "long") \
        (__pomodoro_paint magenta "$long_break") \
        (__pomodoro_paint yellow "cycle") \
        (__pomodoro_paint yellow "$cycle_pomodoros")
end

function __pomodoro_paths --description 'Print all resolved paths and the detected backend for troubleshooting'
    echo "state dir:   "(__pomodoro_state_dir)
    echo "state file:  "(__pomodoro_statefile)
    echo "pid file:    "(__pomodoro_pidfile)
    echo "daemon path: "(__pomodoro_daemon_path)
    echo "backend:     "(__pomodoro_detect_backend)

    switch (uname)
        case Linux
            echo "unit path:   "(__pomodoro_systemd_unit_path)
        case Darwin
            echo "plist path:  "(__pomodoro_launchd_plist_path)
    end
end

function pomodoro --description 'CLI frontend for starting, pausing, resetting, clearing, and inspecting the Pomodoro timer'
    if test (count $argv) -eq 0
        __pomodoro_usage
        return 0
    end

    switch $argv[1]
        case start
            __pomodoro_start $argv[2..-1]

        case stop
            __pomodoro_stop

        case reset restart
            __pomodoro_reset $argv[2..-1]

        case clear
            __pomodoro_clear

        case status
            __pomodoro_status

        case daemon
            set -l daemon (__pomodoro_daemon_path)

            if not test -x "$daemon"
                echo "error: daemon script not executable: $daemon" >&2
                return 1
            end

            # Use the external command directly instead of calling a Fish function.
            # This keeps daemon execution independent from interactive shell state.
            command $daemon

        case paths
            __pomodoro_paths

        case -h --help help
            __pomodoro_usage

        case '*'
            echo "error: unknown subcommand '$argv[1]'" >&2
            echo >&2
            __pomodoro_usage >&2
            return 1
    end
end

function __pomodoro_usage --description 'Print command usage help'
    echo "Usage:"
    echo "  pomodoro start [work_min] [short_break_min] [long_break_min] [cycle_pomodoros]"
    echo "                                      Start a new session or resume a paused one"
    echo "  pomodoro stop                       Pause the current session"
    echo "  pomodoro reset [work_min] [short_break_min] [long_break_min] [cycle_pomodoros]"
    echo "                                      Restart from pomodoro 1 of the cycle"
    echo "  pomodoro restart [work_min] [short_break_min] [long_break_min] [cycle_pomodoros]"
    echo "                                      Alias of reset"
    echo "  pomodoro clear                      Interrupt the session and remove all state"
    echo "  pomodoro status                     Show detailed session status"
    echo "  pomodoro daemon                     Run the standalone daemon in foreground"
    echo "  pomodoro paths                      Show resolved paths and backend"
end

# Shell completions are explicit on purpose: more verbose, easier to debug.
complete -c pomodoro -f -n "not __fish_seen_subcommand_from start stop status reset restart clear daemon paths" \
    -a start -d "Start a new Pomodoro session or resume a paused one"
complete -c pomodoro -f -n "not __fish_seen_subcommand_from start stop status reset restart clear daemon paths" \
    -a stop -d "Pause the current session"
complete -c pomodoro -f -n "not __fish_seen_subcommand_from start stop status reset restart clear daemon paths" \
    -a reset -d "Restart from pomodoro 1"
complete -c pomodoro -f -n "not __fish_seen_subcommand_from start stop status reset restart clear daemon paths" \
    -a restart -d "Alias of reset"
complete -c pomodoro -f -n "not __fish_seen_subcommand_from start stop status reset restart clear daemon paths" \
    -a clear -d "Interrupt session and remove all state"
complete -c pomodoro -f -n "not __fish_seen_subcommand_from start stop status reset restart clear daemon paths" \
    -a status -d "Show detailed session status"
complete -c pomodoro -f -n "not __fish_seen_subcommand_from start stop status reset restart clear daemon paths" \
    -a daemon -d "Run the standalone daemon in foreground"
complete -c pomodoro -f -n "not __fish_seen_subcommand_from start stop status reset restart clear daemon paths" \
    -a paths -d "Show resolved paths and backend"

complete -c pomodoro -n "__fish_seen_subcommand_from start reset restart; and __fish_is_nth_token 2" \
    -x -d "Work duration in minutes"
complete -c pomodoro -n "__fish_seen_subcommand_from start reset restart; and __fish_is_nth_token 3" \
    -x -d "Short-break duration in minutes"
complete -c pomodoro -n "__fish_seen_subcommand_from start reset restart; and __fish_is_nth_token 4" \
    -x -d "Long-break duration in minutes"
complete -c pomodoro -n "__fish_seen_subcommand_from start reset restart; and __fish_is_nth_token 5" \
    -x -d "Number of work sessions per cycle"
