#!/usr/bin/env fish

# =========================================================
# 🍅 Pomodoro Timer — Fish daemon
#
# This script is the long-running backend of the Pomodoro timer.
# It must not be launched by trying to "daemonize" a Fish function from an
# interactive shell. Instead, it should be supervised by a real service manager:
#   - Linux / WSL:  systemd --user
#   - macOS:        launchd LaunchAgent
#
# Responsibilities of this daemon:
#   - read persisted timer state
#   - advance phases when the current one expires
#   - write the next expiration point atomically
#   - notify the user when a phase changes
#   - keep a PID file only for lightweight local tracking/debugging
#
# On WSL, the fullscreen Windows overlay is rendered by powershell.exe using:
#   - a PowerShell template stored in the user's config directory
#   - WebView2 SDK DLLs installed under the current Windows user's LocalAppData
#
# That LocalAppData placement is intentional: Windows PowerShell / .NET Framework
# can reject assembly loads from UNC-style \\wsl.localhost paths, so the DLLs are
# stored on the Windows filesystem instead of under the WSL XDG data directory.
#
# Responsibilities intentionally left to the frontend:
#   - start / resume semantics
#   - pause semantics
#   - reset / clear commands
#   - human-friendly CLI status rendering
#   - installation/bootstrap of optional host-specific assets
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

function __pomodoro_data_dir --description 'Return the directory used for persistent Pomodoro data assets on the WSL/Linux side'
    # This is still useful for non-runtime assets that belong to the Linux/WSL
    # side of the setup. WSL WebView2 DLLs are intentionally NOT stored here,
    # because Windows PowerShell must load them from a Windows-local path.
    if set -q XDG_DATA_HOME; and test -n "$XDG_DATA_HOME"
        echo "$XDG_DATA_HOME/pomodoro"
    else
        echo ~/.local/share/pomodoro
    end
end

function __pomodoro_windows_localappdata_win_dir --description 'Return the current Windows user LocalAppData directory as a Windows path'
    if not command -q powershell.exe
        echo "error: powershell.exe not found" >&2
        return 1
    end

    set -l win_localappdata (powershell.exe -NoProfile -Command "[Environment]::GetFolderPath('LocalApplicationData')" | string trim)

    if test -z "$win_localappdata"
        echo "error: failed to resolve Windows LocalAppData path" >&2
        return 1
    end

    echo "$win_localappdata"
end

function __pomodoro_windows_localappdata_wsl_dir --description 'Return the current Windows user LocalAppData directory as a WSL path'
    if not command -q wslpath
        echo "error: wslpath not found" >&2
        return 1
    end

    set -l win_localappdata (__pomodoro_windows_localappdata_win_dir); or return 1
    wslpath -u "$win_localappdata"
end

function __pomodoro_webview2_dir --description 'Return the Windows-local directory used for WebView2 SDK DLLs, expressed as a WSL path'
    set -l localappdata_wsl (__pomodoro_windows_localappdata_wsl_dir); or return 1
    echo "$localappdata_wsl/pomodoro/webview2"
end

function __pomodoro_webview2_core_dll --description 'Return the expected WebView2 Core DLL path as a WSL path'
    set -l webview2_dir (__pomodoro_webview2_dir); or return 1
    echo "$webview2_dir/Microsoft.Web.WebView2.Core.dll"
end

function __pomodoro_webview2_winforms_dll --description 'Return the expected WebView2 WinForms DLL path as a WSL path'
    set -l webview2_dir (__pomodoro_webview2_dir); or return 1
    echo "$webview2_dir/Microsoft.Web.WebView2.WinForms.dll"
end

function __pomodoro_host_kind --description 'Return the normalized host kind: Linux, Darwin, or WSL'
    # WSL must be detected before generic Linux because uname still reports Linux.
    if test -f /proc/version; and string match -qi '*microsoft*' (cat /proc/version)
        echo WSL
        return 0
    end

    switch (uname)
        case Darwin
            echo Darwin
        case Linux
            echo Linux
        case '*'
            uname
    end
end

function __pomodoro_pidfile --description 'Return the PID file path for daemon tracking'
    # Keep all runtime files under the same state directory so cleanup is trivial
    # and stale files from older runs are easy to reason about.
    echo (__pomodoro_state_dir)/pid
end

function __pomodoro_statefile --description 'Return the session state file path'
    echo (__pomodoro_state_dir)/state
end

function __pomodoro_overlay_logfile --description 'Return the log file path used by the WSL fullscreen overlay'
    echo (__pomodoro_state_dir)/overlay.log
end

function __pomodoro_overlay_pidfile --description 'Return the PID file path for the active WSL overlay process'
    echo (__pomodoro_state_dir)/overlay.pid
end

function __pomodoro_overlay_template_path --description 'Return the PowerShell template path used for the WSL Windows fullscreen overlay'
    echo ~/.config/fish/lib/pomodoro-overlay-wsl-template.ps1
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
    # in PATH. Under systemd --user, that is not guaranteed, so also probe the
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

function __pomodoro_wsl_windows_path --description 'Convert a WSL path to a Windows path usable by powershell.exe'
    set -l path_linux $argv[1]

    if not command -q wslpath
        echo "error: wslpath not found" >&2
        return 1
    end

    wslpath -w "$path_linux"
end

function __pomodoro_escape_for_powershell_double_quoted --description 'Escape text for inclusion in a PowerShell double-quoted string'
    set -l text $argv[1]

    # Escape the PowerShell escape character first so later replacements remain literal.
    # Then escape double quotes and dollar signs because the resulting text is injected
    # into PowerShell double-quoted string literals.
    set text (string replace -a '`' '``' -- "$text")
    set text (string replace -a '"' '`"' -- "$text")
    set text (string replace -a '$' '`$' -- "$text")

    echo "$text"
end

function __pomodoro_escape_for_sed_replacement --description 'Escape text for safe use in a sed replacement'
    set -l text $argv[1]

    # sed replacement strings treat backslash, ampersand, and the chosen
    # delimiter specially. Escape them so template substitutions stay literal.
    set text (string replace -a '\\' '\\\\' -- "$text")
    set text (string replace -a '&' '\\&' -- "$text")
    set text (string replace -a '|' '\\|' -- "$text")

    echo "$text"
end

function __pomodoro_stop_overlay_wsl --description 'Stop the currently running WSL overlay process, if any'
    set -l pidfile (__pomodoro_overlay_pidfile)

    if not test -f "$pidfile"
        return 0
    end

    set -l pid (cat "$pidfile" 2>/dev/null)
    if test -z "$pid"
        rm -f "$pidfile"
        return 0
    end

    if kill -0 "$pid" 2>/dev/null
        kill "$pid" 2>/dev/null
        sleep 0.2

        if kill -0 "$pid" 2>/dev/null
            kill -9 "$pid" 2>/dev/null
        end
    end

    rm -f "$pidfile"
end

function __pomodoro_notify_overlay_wsl --description 'Render the Windows overlay PowerShell template and execute it from WSL'
    set -l title $argv[1]
    set -l msg $argv[2]

    # Only one fullscreen overlay should exist at a time. If a new transition
    # happens before the previous overlay was dismissed, terminate the previous
    # PowerShell process first so overlays do not stack.
    __pomodoro_stop_overlay_wsl

    set -l ps (__pomodoro_find_windows_command powershell.exe)
    if test -z "$ps"
        echo "warning: WSL multi-screen overlay skipped: powershell.exe not found" >&2
        return 1
    end

    set -l template (__pomodoro_overlay_template_path)
    if not test -f "$template"
        echo "warning: WSL overlay template not found: $template" >&2
        return 1
    end

    # The template expects the WebView2 DLL paths as Windows-native paths.
    # First resolve them as WSL paths for existence checks, then convert them
    # back to Windows paths before placeholder substitution.
    set -l core_dll (__pomodoro_webview2_core_dll); or return 1
    set -l forms_dll (__pomodoro_webview2_winforms_dll); or return 1

    if not test -f "$core_dll"
        echo "warning: WebView2 Core DLL not found: $core_dll" >&2
        echo "         run: pomodoro install" >&2
        return 1
    end

    if not test -f "$forms_dll"
        echo "warning: WebView2 WinForms DLL not found: $forms_dll" >&2
        echo "         run: pomodoro install" >&2
        return 1
    end

    set -l core_dll_win (__pomodoro_wsl_windows_path "$core_dll"); or return 1
    set -l forms_dll_win (__pomodoro_wsl_windows_path "$forms_dll"); or return 1

    set -l state_dir (__pomodoro_state_dir)
    set -l log_file (__pomodoro_overlay_logfile)
    set -l overlay_pidfile (__pomodoro_overlay_pidfile)
    mkdir -p "$state_dir"

    # Escape values twice:
    #   1. for PowerShell double-quoted literals inside the generated .ps1
    #   2. for sed replacement semantics while generating that file
    set -l ps_title (__pomodoro_escape_for_powershell_double_quoted "$title")
    set -l ps_msg (__pomodoro_escape_for_powershell_double_quoted "$msg")
    set -l ps_core_dll (__pomodoro_escape_for_powershell_double_quoted "$core_dll_win")
    set -l ps_forms_dll (__pomodoro_escape_for_powershell_double_quoted "$forms_dll_win")

    set -l sed_title (__pomodoro_escape_for_sed_replacement "$ps_title")
    set -l sed_msg (__pomodoro_escape_for_sed_replacement "$ps_msg")
    set -l sed_core_dll (__pomodoro_escape_for_sed_replacement "$ps_core_dll")
    set -l sed_forms_dll (__pomodoro_escape_for_sed_replacement "$ps_forms_dll")

    # Pick a random Ctrl+<letter> chord so the fullscreen overlay is harder to
    # dismiss reflexively. The chosen key is injected both into the UI hint and
    # into the JavaScript / form-level key handlers.
    set -l letters A B C D E F G H I J K L M N O P Q R S T U V W X Y Z
    set -l dismiss_key $letters[(random 1 (count $letters))]
    set -l sed_dismiss_key (__pomodoro_escape_for_sed_replacement "$dismiss_key")

    set -l ps1 "$state_dir/overlay.generated.ps1"

    # Windows PowerShell handles UTF-8 with BOM more reliably for non-ASCII
    # content such as emojis. The generated file is ephemeral runtime state.
    printf '\xEF\xBB\xBF' >"$ps1"
    sed \
        -e "s|__POMODORO_OVERLAY_TITLE__|$sed_title|g" \
        -e "s|__POMODORO_OVERLAY_MESSAGE__|$sed_msg|g" \
        -e "s|__POMODORO_OVERLAY_DISMISS_KEY__|$sed_dismiss_key|g" \
        -e "s|__POMODORO_WEBVIEW2_CORE_DLL__|$sed_core_dll|g" \
        -e "s|__POMODORO_WEBVIEW2_WINFORMS_DLL__|$sed_forms_dll|g" \
        "$template" >>"$ps1"

    "$ps" -NoProfile -ExecutionPolicy Bypass -STA -File "$ps1" >>"$log_file" 2>&1 &
    set -l launch_status $status

    if test $launch_status -eq 0
        echo "$last_pid" >"$overlay_pidfile"
    end

    if test $launch_status -ne 0
        echo "warning: failed to launch WSL multi-screen overlay powershell process" >&2
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
    # when the fullscreen overlay fails to initialize but plain PowerShell toast
    # notifications still work.
    set -l ps_cmd (string join \n -- \
        '[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null' \
        '$template = [Windows.UI.Notifications.ToastTemplateType]::ToastText02' \
        '$xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent($template)' \
        '$text = $xml.GetElementsByTagName("text")' \
        '[void]$text.Item(0).AppendChild($xml.CreateTextNode("__POMODORO_OVERLAY_TITLE__"))' \
        '[void]$text.Item(1).AppendChild($xml.CreateTextNode("__POMODORO_OVERLAY_MESSAGE__"))' \
        '$toast = [Windows.UI.Notifications.ToastNotification]::new($xml)' \
        '[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("PowerShell").Show($toast)' \
    )

    set ps_cmd (string replace -a '__POMODORO_OVERLAY_TITLE__' "$ps_title" -- "$ps_cmd")
    set ps_cmd (string replace -a '__POMODORO_OVERLAY_MESSAGE__' "$ps_msg" -- "$ps_cmd")

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
    set -l title $argv[2]

    if test -z "$title"
        set title Pomodoro
    end

    switch (__pomodoro_host_kind)
        case WSL
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

        case Darwin
            if command -q osascript
                osascript -e "display notification \"$msg\" with title \"$title\"" >/dev/null 2>&1
                return $status
            end

        case Linux
            if command -q notify-send
                notify-send "$title" "$msg" >/dev/null 2>&1
                return $status
            end
    end

    return 1
end

function __pomodoro_cleanup --on-process-exit %self --description 'Remove our PID file and any active WSL overlay when this daemon exits'
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

    __pomodoro_stop_overlay_wsl
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

function __pomodoro_repeat_symbol --description 'Repeat a symbol N times'
    set -l symbol $argv[1]
    set -l count_n $argv[2]

    if test "$count_n" -le 0
        return 0
    end

    for i in (seq "$count_n")
        printf '%s' "$symbol"
    end
end

function __pomodoro_progress_completed --description 'Return number of completed pomodoros in the current cycle context'
    set -l mode $argv[1]
    set -l pomodoro_index $argv[2]

    switch "$mode"
        case work
            # While working on pomodoro N, completed pomodoros are N-1.
            math "$pomodoro_index - 1"
        case short_break long_break
            # During a break after pomodoro N, completed pomodoros are N.
            echo "$pomodoro_index"
    end
end

function __pomodoro_notification_progress_icons --description 'Render cycle progress for notifications using filled and empty icons'
    set -l mode $argv[1]
    set -l pomodoro_index $argv[2]
    set -l cycle_pomodoros $argv[3]

    set -l completed (__pomodoro_progress_completed "$mode" "$pomodoro_index")
    set -l remaining (math "$cycle_pomodoros - $completed")

    set -l filled (__pomodoro_repeat_symbol '🔴' "$completed")
    set -l empty (__pomodoro_repeat_symbol '◯ ' "$remaining")

    printf '%s%s' "$filled" "$empty"
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
    set -l notify_title
    set -l notify_msg

    # Cycle semantics:
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
            else
                set next_mode short_break
                set next_duration_sec (math "$short_break * 60")
                set next_pomodoro_index $pomodoro_index
            end

        case short_break
            set next_mode work
            set next_duration_sec (math "$work * 60")
            set next_pomodoro_index (math "$pomodoro_index + 1")

        case long_break
            set next_mode work
            set next_duration_sec (math "$work * 60")
            set next_pomodoro_index 1

        case '*'
            echo "warning: unknown mode '$mode', ignoring state update" >&2
            return 1
    end

    # Anchor the next phase to the current time, not to the previous deadline.
    # This avoids drift accumulation if the daemon wakes up slightly late.
    set -l new_end (math "$now_epoch + $next_duration_sec")

    __pomodoro_write_state running "$next_mode" "$new_end" 0 "$work" "$short_break" "$long_break" "$cycle_pomodoros" "$next_pomodoro_index"

    set -l progress_icons (__pomodoro_notification_progress_icons "$next_mode" "$next_pomodoro_index" "$cycle_pomodoros")

    switch "$mode"
        case work
            set notify_title "Pomodoro $progress_icons completed"

            if test "$pomodoro_index" -ge "$cycle_pomodoros"
                set notify_msg "Long break time! 🧘"
            else
                set notify_msg "Short break time! 🧘"
            end

        case short_break
            set notify_title "☕ Break finished"
            set notify_msg "$progress_icons  Back to work 💪"

        case long_break
            set notify_title "🌴 Long break finished"
            set notify_msg "$progress_icons  New cycle starts now 💪"
    end

    echo "info: transitioned $mode -> $next_mode (pomodoro $next_pomodoro_index/$cycle_pomodoros)" >&2
    __pomodoro_notify "$notify_msg" "$notify_title"
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
