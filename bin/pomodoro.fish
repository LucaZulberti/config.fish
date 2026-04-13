#!/usr/bin/env fish

# =========================================================
# 🍅 Pomodoro Timer — Fish daemon
#
# This script is the long-running backend of the Pomodoro timer.
# It must not be launched by trying to "daemonize" a Fish function from an
# interactive shell. Instead, it should be supervised by a real service manager:
#   - Linux:  systemd --user
#   - macOS:  launchd LaunchAgent
#
# Responsibilities of this daemon:
#   - read persisted timer state
#   - advance phases when the current one expires
#   - write the next expiration point atomically
#   - notify the user when a phase changes
#   - keep a PID file only for lightweight local tracking/debugging
#
# Responsibilities intentionally left to the frontend:
#   - start / resume semantics
#   - pause semantics
#   - reset / clear commands
#   - human-friendly CLI status rendering
# =========================================================

function __pomodoro_state_dir --description 'Return the directory used for persistent timer state'
    # Prefer XDG_STATE_HOME when available so the daemon follows the standard
    # XDG state layout and integrates cleanly with the rest of the user setup.
    # Fall back to ~/.local/state for environments that do not export it.
    if set -q XDG_STATE_HOME; and test -n "$XDG_STATE_HOME"
        echo "$XDG_STATE_HOME/pomodoro"
    else
        echo ~/.local/state/pomodoro
    end
end

function __pomodoro_pidfile --description 'Return the PID file path for daemon tracking'
    # Keep all files under the same state directory so cleanup is trivial and
    # stale files from older runs are easy to reason about.
    echo (__pomodoro_state_dir)/pid
end

function __pomodoro_statefile --description 'Return the session state file path'
    echo (__pomodoro_state_dir)/state
end

function __pomodoro_overlay_logfile --description 'Return the log file path used by the WSL fullscreen overlay'
    echo (__pomodoro_state_dir)/overlay.log
end

function __pomodoro_write_state --description 'Atomically rewrite the session state file'
    set -l run_state_name $argv[1]
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

    # Write to a temporary file first, then rename it over the real state file.
    # The rename is atomic on the same filesystem, so readers never observe a
    # half-written file during a phase transition.
    printf "%s\n" \
        "set run_state $run_state_name" \
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

function __pomodoro_find_windows_command --description 'Resolve a Windows executable from WSL, even in restricted service environments'
    set -l name $argv[1]

    # In an interactive WSL shell, Windows executables are often already present
    # in PATH. Under systemd --user, that is not guaranteed, so we also probe the
    # canonical mounted Windows paths explicitly.
    if command -q $name
        command -s $name
        return 0
    end

    switch "$name"
        case powershell.exe
            for candidate in \
                /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe \
                /mnt/c/Windows/System32/WindowsPowerShell/v1.0/PowerShell.exe
                if test -x "$candidate"
                    echo "$candidate"
                    return 0
                end
            end

        case cmd.exe
            for candidate in \
                /mnt/c/Windows/System32/cmd.exe \
                /mnt/c/Windows/SysWOW64/cmd.exe
                if test -x "$candidate"
                    echo "$candidate"
                    return 0
                end
            end
    end

    return 1
end

function __pomodoro_escape_for_powershell_double_quoted --description 'Escape text for inclusion in a PowerShell double-quoted string'
    set -l text $argv[1]

    # Escape the PowerShell escape character first so later replacements remain literal.
    # Then escape double quotes and dollar signs because we inject the resulting text
    # into PowerShell double-quoted string literals.
    set text (string replace -a '`' '``' -- "$text")
    set text (string replace -a '"' '`"' -- "$text")
    set text (string replace -a '$' '`$' -- "$text")

    echo "$text"
end

function __pomodoro_notify_overlay_wsl --description 'Show a fullscreen Windows WPF overlay from WSL using a temporary .ps1 script'
    set -l title $argv[1]
    set -l msg $argv[2]

    set -l ps (__pomodoro_find_windows_command powershell.exe)
    if test -z "$ps"
        echo "warning: WSL overlay skipped: powershell.exe not found" >&2
        return 1
    end

    set -l state_dir (__pomodoro_state_dir)
    set -l log_file (__pomodoro_overlay_logfile)
    mkdir -p "$state_dir"

    set -l ps_title (__pomodoro_escape_for_powershell_double_quoted "$title")
    set -l ps_msg (__pomodoro_escape_for_powershell_double_quoted "$msg")

    set -l ps1 (mktemp "$state_dir/overlay.XXXXXX.ps1")

    set -l ps_lines \
        "\$ErrorActionPreference = 'Stop'" \
        "" \
        "try {" \
        "    Add-Type -AssemblyName PresentationCore,PresentationFramework,WindowsBase" \
        "" \
        "    \$window = New-Object System.Windows.Window" \
        "    \$window.Title = 'PomodoroOverlay'" \
        "    \$window.WindowStyle = 'None'" \
        "    \$window.ResizeMode = 'NoResize'" \
        "    \$window.WindowState = 'Maximized'" \
        "    \$window.Topmost = \$true" \
        "    \$window.ShowInTaskbar = \$false" \
        "    \$window.ShowActivated = \$true" \
        "    \$window.AllowsTransparency = \$true" \
        "    \$window.Focusable = \$true" \
        "    \$window.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(235,0,0,0))" \
        "" \
        "    \$grid = New-Object System.Windows.Controls.Grid" \
        "    \$grid.Focusable = \$true" \
        "" \
        "    \$stack = New-Object System.Windows.Controls.StackPanel" \
        "    \$stack.HorizontalAlignment = 'Center'" \
        "    \$stack.VerticalAlignment = 'Center'" \
        "    \$stack.MaxWidth = 1200" \
        "" \
        "    \$icon = New-Object System.Windows.Controls.TextBlock" \
        "    \$icon.Text = [System.Char]::ConvertFromUtf32(0x1F345)" \
        "    \$icon.FontSize = 104" \
        "    \$icon.HorizontalAlignment = 'Center'" \
        "    \$icon.Foreground = [System.Windows.Media.Brushes]::Tomato" \
        "    \$icon.Margin = '0,0,0,24'" \
        "" \
        "    \$tb1 = New-Object System.Windows.Controls.TextBlock" \
        "    \$tb1.Text = '__TITLE__'" \
        "    \$tb1.FontSize = 44" \
        "    \$tb1.FontWeight = 'Bold'" \
        "    \$tb1.HorizontalAlignment = 'Center'" \
        "    \$tb1.Foreground = [System.Windows.Media.Brushes]::White" \
        "    \$tb1.Margin = '0,0,0,12'" \
        "" \
        "    \$tb2 = New-Object System.Windows.Controls.TextBlock" \
        "    \$tb2.Text = '__MSG__'" \
        "    \$tb2.FontSize = 28" \
        "    \$tb2.TextWrapping = 'Wrap'" \
        "    \$tb2.TextAlignment = 'Center'" \
        "    \$tb2.HorizontalAlignment = 'Center'" \
        "    \$tb2.Foreground = [System.Windows.Media.Brushes]::White" \
        "    \$tb2.MaxWidth = 1000" \
        "    \$tb2.Margin = '0,0,0,24'" \
        "" \
        "    \$tb3 = New-Object System.Windows.Controls.TextBlock" \
        "    \$tb3.Text = 'Ctrl+C, Esc, or click to dismiss'" \
        "    \$tb3.FontSize = 18" \
        "    \$tb3.HorizontalAlignment = 'Center'" \
        "    \$tb3.Foreground = [System.Windows.Media.Brushes]::LightGray" \
        "" \
        "    [void]\$stack.Children.Add(\$icon)" \
        "    [void]\$stack.Children.Add(\$tb1)" \
        "    [void]\$stack.Children.Add(\$tb2)" \
        "    [void]\$stack.Children.Add(\$tb3)" \
        "    [void]\$grid.Children.Add(\$stack)" \
        "    \$window.Content = \$grid" \
        "" \
        "    function Close-OverlayIfDismissKey {" \
        "        param(\$windowRef, \$e)" \
        "        \$ctrl = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0" \
        "        if ((\$ctrl -and \$e.Key -eq [System.Windows.Input.Key]::C) -or (\$e.Key -eq [System.Windows.Input.Key]::Escape)) {" \
        "            \$e.Handled = \$true" \
        "            \$windowRef.Close()" \
        "        }" \
        "    }" \
        "" \
        "    # Focus is the hard part here. Clicking already proves the window exists;" \
        "    # repeated Activate/Focus attempts improve the odds that keyboard events" \
        "    # start reaching the overlay without an initial click." \
        "    \$focusAction = {" \
        "        try {" \
        "            \$window.Activate() | Out-Null" \
        "            [System.Windows.Input.FocusManager]::SetFocusedElement(\$window, \$grid)" \
        "            \$window.Focus() | Out-Null" \
        "            \$grid.Focus() | Out-Null" \
        "            [System.Windows.Input.Keyboard]::Focus(\$grid) | Out-Null" \
        "        } catch {}" \
        "    }" \
        "" \
        "    \$window.Add_ContentRendered({" \
        "        param(\$sender, \$e)" \
        "        & \$focusAction" \
        "" \
        "        \$focusTimer = New-Object System.Windows.Threading.DispatcherTimer" \
        "        \$focusTimer.Interval = [TimeSpan]::FromMilliseconds(250)" \
        "        \$script:focusAttempts = 0" \
        "        \$focusTimer.Add_Tick({" \
        "            param(\$tickSender, \$tickEventArgs)" \
        "            & \$focusAction" \
        "            \$script:focusAttempts++" \
        "            if (\$script:focusAttempts -ge 8 -and \$null -ne \$tickSender) {" \
        "                \$tickSender.Stop()" \
        "            }" \
        "        })" \
        "        \$focusTimer.Start()" \
        "    })" \
        "" \
        "    \$window.Add_PreviewKeyDown({" \
        "        param(\$sender, \$e)" \
        "        Close-OverlayIfDismissKey \$window \$e" \
        "    })" \
        "" \
        "    \$grid.Add_PreviewKeyDown({" \
        "        param(\$sender, \$e)" \
        "        Close-OverlayIfDismissKey \$window \$e" \
        "    })" \
        "" \
        "    \$window.Add_MouseLeftButtonDown({" \
        "        \$window.Close()" \
        "    })" \
        "" \
        "    \$app = New-Object System.Windows.Application" \
        "    \$app.ShutdownMode = 'OnMainWindowClose'" \
        "    [void]\$app.Run(\$window)" \
        "}" \
        "catch {" \
        "    [Console]::Error.WriteLine('overlay error: ' + \$_.Exception.Message)" \
        "    exit 1" \
        "}"

    set -l rendered_lines
    for line in $ps_lines
        set line (string replace -a '__TITLE__' "$ps_title" -- "$line")
        set line (string replace -a '__MSG__' "$ps_msg" -- "$line")
        set -a rendered_lines "$line"
    end

    printf '\xEF\xBB\xBF' >"$ps1"
    printf '%s\n' $rendered_lines >>"$ps1"

    "$ps" -NoProfile -ExecutionPolicy Bypass -STA -File "$ps1" >>"$log_file" 2>&1 &
    set -l launch_status $status

    if test $launch_status -ne 0
        echo "warning: failed to launch WSL overlay powershell process" >&2
        return 1
    end

    return 0
end

function __pomodoro_notify_toast_wsl --description 'Send a Windows toast notification from WSL using powershell.exe'
    set -l title $argv[1]
    set -l msg $argv[2]

    set -l ps (__pomodoro_find_windows_command powershell.exe)
    if test -z "$ps"
        echo "warning: WSL toast skipped: powershell.exe not found" >&2
        return 1
    end

    set -l ps_title (__pomodoro_escape_for_powershell_double_quoted "$title")
    set -l ps_msg (__pomodoro_escape_for_powershell_double_quoted "$msg")

    # This is a fallback behind the fullscreen overlay path. It remains useful
    # when WPF fails to initialize but plain PowerShell toast notifications work.
    set -l ps_cmd (string join \n -- \
        '[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null' \
        '$template = [Windows.UI.Notifications.ToastTemplateType]::ToastText02' \
        '$xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent($template)' \
        '$text = $xml.GetElementsByTagName("text")' \
        '[void]$text.Item(0).AppendChild($xml.CreateTextNode("__TITLE__"))' \
        '[void]$text.Item(1).AppendChild($xml.CreateTextNode("__MSG__"))' \
        '$toast = [Windows.UI.Notifications.ToastNotification]::new($xml)' \
        '[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("PowerShell").Show($toast)' \
    )

    set ps_cmd (string replace -a '__TITLE__' "$ps_title" -- "$ps_cmd")
    set ps_cmd (string replace -a '__MSG__' "$ps_msg" -- "$ps_cmd")

    set -l errfile (mktemp)

    "$ps" -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$ps_cmd" >/dev/null 2>"$errfile"
    set -l ps_status $status

    if test $ps_status -eq 0
        rm -f "$errfile"
        return 0
    end

    set -l ps_err ''
    if test -s "$errfile"
        set ps_err (string join ' ' -- (cat "$errfile"))
    end
    rm -f "$errfile"

    echo "warning: powershell toast failed (exit $ps_status): $ps_err" >&2
    return 1
end

function __pomodoro_notify_msg_wsl --description 'Send a minimal Windows message-box style notification from WSL via cmd.exe'
    set -l title $argv[1]
    set -l msg $argv[2]

    set -l cmd (__pomodoro_find_windows_command cmd.exe)
    if test -z "$cmd"
        echo "warning: WSL message fallback skipped: cmd.exe not found" >&2
        return 1
    end

    # This is the lowest-common-denominator fallback. It is visually worse than
    # overlay/toast, but still better than losing the event completely.
    "$cmd" /c msg '*' "$title - $msg" >/dev/null 2>&1
    return $status
end

function __pomodoro_notify --description 'Send a desktop notification on the current host platform'
    set -l msg $argv[1]
    set -l title '🍅 Pomodoro'

    # WSL must be detected before the generic Linux branch because, from the
    # kernel perspective, it still looks like Linux.
    #
    # On WSL, prefer a fullscreen Windows overlay because it is intentionally hard
    # to miss. If that launch fails, fall back to a normal Windows toast. If that
    # also fails, fall back to cmd.exe /c msg.
    if test -f /proc/version; and string match -qi '*microsoft*' (cat /proc/version)
        if __pomodoro_notify_overlay_wsl "$title" "$msg"
            return 0
        end

        if __pomodoro_notify_toast_wsl "$title" "$msg"
            return 0
        end

        if __pomodoro_notify_msg_wsl "$title" "$msg"
            return 0
        end

        echo "warning: all WSL notification methods failed" >&2
        return 1
    end

    switch (uname)
        case Darwin
            # osascript is the simplest native way to surface a notification from
            # a user agent on macOS without adding extra dependencies.
            if command -q osascript
                osascript -e "display notification \"$msg\" with title \"$title\"" >/dev/null 2>&1
                return $status
            end

        case Linux
            # notify-send relies on the user desktop notification service. Under
            # systemd --user this usually works well when the session environment
            # is correct, and degrades gracefully when it is not available.
            if command -q notify-send
                notify-send "$title" "$msg" >/dev/null 2>&1
                return $status
            end
    end

    return 1
end

function __pomodoro_cleanup --on-process-exit %self --description 'Remove our PID file when this daemon exits'
    set -l pidfile (__pomodoro_pidfile)

    if test -f "$pidfile"
        set -l current_pid (cat "$pidfile" 2>/dev/null)

        # Only remove the PID file when it still points to this exact process.
        # This prevents a newer daemon instance from losing its PID file if an
        # older instance exits slightly later.
        if test "$current_pid" = "$fish_pid"
            rm -f "$pidfile"
        end
    end
end

function __pomodoro_validate_positive_int --description 'Validate a positive integer field'
    set -l field_name $argv[1]
    set -l value $argv[2]

    if not string match -qr '^[1-9][0-9]*$' -- "$value"
        echo "warning: invalid state field '$field_name' (expected positive integer, got '$value')" >&2
        return 1
    end
end

function __pomodoro_validate_uint --description 'Validate a non-negative integer field'
    set -l field_name $argv[1]
    set -l value $argv[2]

    if not string match -qr '^[0-9]+$' -- "$value"
        echo "warning: invalid state field '$field_name' (expected non-negative integer, got '$value')" >&2
        return 1
    end
end

function __pomodoro_read_state --description 'Read and validate the persisted state, then print it as 9 lines'
    set -l statefile (__pomodoro_statefile)

    if not test -f "$statefile"
        return 1
    end

    # Parse the state file explicitly instead of sourcing it.
    #
    # The frontend writes a very small, stable format:
    #   set key value
    #
    # Parsing it ourselves is more robust than `source` because it avoids subtle
    # scope interactions, side effects, and hard-to-debug failures if the file is
    # partially written or contains unexpected content.
    set -l run_state ''
    set -l mode ''
    set -l end ''
    set -l remaining ''
    set -l work ''
    set -l short_break ''
    set -l long_break ''
    set -l cycle_pomodoros ''
    set -l pomodoro_index ''

    while read -l cmd key value
        if test -z "$cmd"
            continue
        end

        if test "$cmd" != set
            echo "warning: invalid state file: unexpected command '$cmd'" >&2
            return 1
        end

        switch "$key"
            case run_state
                set run_state "$value"
            case mode
                set mode "$value"
            case end
                set end "$value"
            case remaining
                set remaining "$value"
            case work
                set work "$value"
            case short_break
                set short_break "$value"
            case long_break
                set long_break "$value"
            case cycle_pomodoros
                set cycle_pomodoros "$value"
            case pomodoro_index
                set pomodoro_index "$value"
            case '*'
                echo "warning: invalid state file: unexpected key '$key'" >&2
                return 1
        end
    end <"$statefile"

    # Check for presence first so later math never receives empty strings.
    if test -z "$run_state"
        echo "warning: invalid state file: missing run_state" >&2
        return 1
    end
    if test -z "$mode"
        echo "warning: invalid state file: missing mode" >&2
        return 1
    end
    if test -z "$end"
        echo "warning: invalid state file: missing end" >&2
        return 1
    end
    if test -z "$remaining"
        echo "warning: invalid state file: missing remaining" >&2
        return 1
    end
    if test -z "$work"
        echo "warning: invalid state file: missing work" >&2
        return 1
    end
    if test -z "$short_break"
        echo "warning: invalid state file: missing short_break" >&2
        return 1
    end
    if test -z "$long_break"
        echo "warning: invalid state file: missing long_break" >&2
        return 1
    end
    if test -z "$cycle_pomodoros"
        echo "warning: invalid state file: missing cycle_pomodoros" >&2
        return 1
    end
    if test -z "$pomodoro_index"
        echo "warning: invalid state file: missing pomodoro_index" >&2
        return 1
    end

    # Validate enums before integers so diagnostics stay precise.
    switch "$run_state"
        case running paused
        case '*'
            echo "warning: invalid state file: invalid run_state '$run_state'" >&2
            return 1
    end

    switch "$mode"
        case work short_break long_break
        case '*'
            echo "warning: invalid state file: invalid mode '$mode'" >&2
            return 1
    end

    __pomodoro_validate_uint end "$end"; or return 1
    __pomodoro_validate_uint remaining "$remaining"; or return 1
    __pomodoro_validate_positive_int work "$work"; or return 1
    __pomodoro_validate_positive_int short_break "$short_break"; or return 1
    __pomodoro_validate_positive_int long_break "$long_break"; or return 1
    __pomodoro_validate_positive_int cycle_pomodoros "$cycle_pomodoros"; or return 1
    __pomodoro_validate_positive_int pomodoro_index "$pomodoro_index"; or return 1

    # Emit one field per line so the caller can read everything back into a Fish
    # list with stable positional indexes.
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

function __pomodoro_transition --description 'Advance to the next phase and write the updated expiration point'
    set -l now_epoch $argv[1]
    set -l mode $argv[2]
    set -l work $argv[3]
    set -l short_break $argv[4]
    set -l long_break $argv[5]
    set -l cycle_pomodoros $argv[6]
    set -l pomodoro_index $argv[7]

    set -l next_mode
    set -l next_duration_sec
    set -l next_pomodoro_index
    set -l notify_msg

    # The cycle semantics are:
    #   work -> short_break until the last pomodoro of the cycle
    #   work -> long_break after the last pomodoro of the cycle
    #   short_break -> next work session in the same cycle
    #   long_break -> work 1 of a new cycle
    switch "$mode"
        case work
            if test "$pomodoro_index" -ge "$cycle_pomodoros"
                set next_mode long_break
                set next_duration_sec (math "$long_break * 60")
                set next_pomodoro_index $pomodoro_index
                set notify_msg "Pomodoro $pomodoro_index/$cycle_pomodoros completed. Long break time! 🧘"
            else
                set next_mode short_break
                set next_duration_sec (math "$short_break * 60")
                set next_pomodoro_index $pomodoro_index
                set notify_msg "Pomodoro $pomodoro_index/$cycle_pomodoros completed. Short break time! 🧘"
            end

        case short_break
            set next_mode work
            set next_duration_sec (math "$work * 60")
            set next_pomodoro_index (math "$pomodoro_index + 1")
            set notify_msg "Break over. Back to work: pomodoro $next_pomodoro_index/$cycle_pomodoros 💪"

        case long_break
            set next_mode work
            set next_duration_sec (math "$work * 60")
            set next_pomodoro_index 1
            set notify_msg 'Long break over. New cycle starts now 💪'

        case '*'
            echo "warning: unknown mode '$mode', ignoring state update" >&2
            return 1
    end

    # Anchor the next phase to the current time, not to the previous deadline.
    # This avoids drift accumulation if the daemon wakes up slightly late.
    set -l new_end (math "$now_epoch + $next_duration_sec")

    __pomodoro_write_state running "$next_mode" "$new_end" 0 "$work" "$short_break" "$long_break" "$cycle_pomodoros" "$next_pomodoro_index"

    echo "info: transitioned $mode -> $next_mode (pomodoro $next_pomodoro_index/$cycle_pomodoros)" >&2
    __pomodoro_notify "$notify_msg"
end

function main --description 'Run the Pomodoro daemon main loop'
    set -l state_dir (__pomodoro_state_dir)
    set -l pidfile (__pomodoro_pidfile)
    set -l statefile (__pomodoro_statefile)

    mkdir -p "$state_dir"

    if test -f "$pidfile"
        set -l existing_pid (cat "$pidfile" 2>/dev/null)

        # Refuse to start if another instance is alive. A second daemon would
        # race on the same state file and produce duplicate notifications.
        if test -n "$existing_pid"; and kill -0 "$existing_pid" 2>/dev/null
            echo "error: daemon already running (pid $existing_pid)" >&2
            return 1
        end

        # If the PID file exists but the process is gone, treat it as stale and
        # recover automatically instead of forcing manual cleanup.
        rm -f "$pidfile"
    end

    echo "$fish_pid" >"$pidfile"

    while true
        if not test -f "$statefile"
            # No active session yet. Stay idle and wait for the frontend to write
            # a new state file.
            sleep 1
            continue
        end

        set -l state (__pomodoro_read_state)
        set -l state_status $status

        if test $state_status -ne 0
            # If the state file is briefly invalid during an update, or has been
            # corrupted by manual edits, avoid crashing the daemon. Just wait for
            # the next valid rewrite.
            sleep 1
            continue
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
            # In paused mode the frontend has already stored the remaining time.
            # The daemon must not advance anything until the session is resumed.
            sleep 1
            continue
        end

        if test "$run_state" != running
            echo "warning: unknown run_state '$run_state', waiting for next update" >&2
            sleep 1
            continue
        end

        set -l now_epoch (date +%s)

        if test "$now_epoch" -ge "$end"
            __pomodoro_transition "$now_epoch" "$mode" "$work" "$short_break" "$long_break" "$cycle_pomodoros" "$pomodoro_index"
        end

        # A one-second polling interval is more than enough for a minute-based
        # timer, while keeping implementation complexity very low.
        sleep 1
    end
end

main
