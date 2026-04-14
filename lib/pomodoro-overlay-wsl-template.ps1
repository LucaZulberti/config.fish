$ErrorActionPreference = 'Stop'

try {
    Add-Type -AssemblyName PresentationCore,PresentationFramework,WindowsBase,System.Windows.Forms

    $title = "__POMODORO_OVERLAY_TITLE__"
    $message = "__POMODORO_OVERLAY_MESSAGE__"
    $dismissKeyName = "__POMODORO_OVERLAY_DISMISS_KEY__"
    $dismissKey = [System.Enum]::Parse([System.Windows.Input.Key], $dismissKeyName, $true)

    $app = New-Object System.Windows.Application
    $app.ShutdownMode = 'OnLastWindowClose'

    # Keep strong references to all windows so one dismiss action can close the
    # full overlay set across all connected screens.
    $windows = New-Object System.Collections.ArrayList

    $primaryWindow = $null
    $primaryFocusTarget = $null

    function Close-AllOverlays {
        param($sender, $e)

        try {
            if ($null -ne $e -and $e.PSObject.Properties.Name -contains 'Handled') {
                $e.Handled = $true
            }
        } catch {}

        foreach ($w in @($windows)) {
            try {
                if ($null -ne $w) {
                    $w.Close()
                }
            } catch {}
        }
    }

    function Close-IfDismissChord {
        param($sender, $e)

        $ctrl = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
        if ($ctrl -and $e.Key -eq $dismissKey) {
            Close-AllOverlays $sender $e
        }
    }

    function New-OverlayWindow {
        param(
            $screen,
            [string]$overlayTitle,
            [string]$overlayMessage,
            [string]$dismissHint
        )

        $window = New-Object System.Windows.Window
        $window.Title = 'PomodoroOverlay'
        $window.WindowStyle = 'None'
        $window.ResizeMode = 'NoResize'
        $window.Topmost = $true
        $window.ShowInTaskbar = $false
        $window.ShowActivated = $true
        $window.AllowsTransparency = $true
        $window.Focusable = $true
        $window.WindowStartupLocation = 'Manual'
        $window.Background = New-Object System.Windows.Media.SolidColorBrush(
            [System.Windows.Media.Color]::FromArgb(235, 0, 0, 0)
        )

        # Cover exactly this physical screen.
        $bounds = $screen.Bounds
        $window.Left = [double]$bounds.X
        $window.Top = [double]$bounds.Y
        $window.Width = [double]$bounds.Width
        $window.Height = [double]$bounds.Height

        $root = New-Object System.Windows.Controls.Grid
        $root.Focusable = $true

        $stack = New-Object System.Windows.Controls.StackPanel
        $stack.HorizontalAlignment = 'Center'
        $stack.VerticalAlignment = 'Center'
        $stack.MaxWidth = 1200

        $icon = New-Object System.Windows.Controls.TextBlock
        $icon.Text = [System.Char]::ConvertFromUtf32(0x1F345)
        $icon.FontSize = 104
        $icon.HorizontalAlignment = 'Center'
        $icon.Foreground = [System.Windows.Media.Brushes]::Tomato
        $icon.Margin = '0,0,0,24'

        $tb1 = New-Object System.Windows.Controls.TextBlock
        $tb1.Text = $overlayTitle
        $tb1.FontSize = 44
        $tb1.FontWeight = 'Bold'
        $tb1.HorizontalAlignment = 'Center'
        $tb1.Foreground = [System.Windows.Media.Brushes]::White
        $tb1.Margin = '0,0,0,12'

        $tb2 = New-Object System.Windows.Controls.TextBlock
        $tb2.Text = $overlayMessage
        $tb2.FontSize = 28
        $tb2.TextWrapping = 'Wrap'
        $tb2.TextAlignment = 'Center'
        $tb2.HorizontalAlignment = 'Center'
        $tb2.Foreground = [System.Windows.Media.Brushes]::White
        $tb2.MaxWidth = 1000
        $tb2.Margin = '0,0,0,24'

        $tb3 = New-Object System.Windows.Controls.TextBlock
        $tb3.Text = $dismissHint
        $tb3.FontSize = 18
        $tb3.HorizontalAlignment = 'Center'
        $tb3.Foreground = [System.Windows.Media.Brushes]::LightGray

        # Use an explicit focusable control as the preferred keyboard target.
        # This is more reliable than trying to keep focus on a panel alone.
        $focusButton = New-Object System.Windows.Controls.Button
        $focusButton.Content = 'Dismiss'
        $focusButton.FontSize = 16
        $focusButton.Padding = '18,8,18,8'
        $focusButton.Margin = '0,8,0,0'
        $focusButton.HorizontalAlignment = 'Center'
        $focusButton.Opacity = 0.01
        $focusButton.Focusable = $true

        [void]$stack.Children.Add($icon)
        [void]$stack.Children.Add($tb1)
        [void]$stack.Children.Add($tb2)
        [void]$stack.Children.Add($tb3)
        [void]$stack.Children.Add($focusButton)
        [void]$root.Children.Add($stack)
        $window.Content = $root

        # Only keyboard dismissal is enabled.
        $window.Add_PreviewKeyDown({
            param($sender, $e)
            Close-IfDismissChord $sender $e
        })

        $focusButton.Add_PreviewKeyDown({
            param($sender, $e)
            Close-IfDismissChord $sender $e
        })

        [pscustomobject]@{
            Window      = $window
            FocusTarget = $focusButton
        }
    }

    $screens = [System.Windows.Forms.Screen]::AllScreens
    if ($null -eq $screens -or $screens.Count -eq 0) {
        throw 'No screens detected for overlay'
    }

    $dismissHint = "Press Ctrl+$dismissKeyName to dismiss on all screens"

    foreach ($screen in $screens) {
        $overlay = New-OverlayWindow $screen $title $message $dismissHint

        [void]$windows.Add($overlay.Window)

        if ($screen.Primary -and $null -eq $primaryWindow) {
            $primaryWindow = $overlay.Window
            $primaryFocusTarget = $overlay.FocusTarget
        }
    }

    if ($null -eq $primaryWindow) {
        $primaryWindow = $windows[0]
        $primaryFocusTarget = $primaryWindow.Content
    }

    $focusAction = {
        param($targetWindow, $targetElement)

        try {
            $targetWindow.Activate() | Out-Null
            [System.Windows.Input.FocusManager]::SetFocusedElement($targetWindow, $targetElement)
            $targetWindow.Focus() | Out-Null
            $targetElement.Focus() | Out-Null
            [System.Windows.Input.Keyboard]::Focus($targetElement) | Out-Null
        } catch {}
    }

    # Background-launched windows may lose the first activation attempt.
    # Retry focus briefly on the primary overlay.
    $primaryWindow.Add_ContentRendered({
        param($sender, $e)

        & $focusAction $primaryWindow $primaryFocusTarget

        $focusTimer = New-Object System.Windows.Threading.DispatcherTimer
        $focusTimer.Interval = [TimeSpan]::FromMilliseconds(250)
        $script:focusAttempts = 0

        $focusTimer.Add_Tick({
            param($tickSender, $tickArgs)

            & $focusAction $primaryWindow $primaryFocusTarget
            $script:focusAttempts++

            if ($script:focusAttempts -ge 8 -and $null -ne $tickSender) {
                $tickSender.Stop()
            }
        })

        $focusTimer.Start()
    })

    foreach ($w in @($windows)) {
        $w.Show()
    }

    [void]$app.Run()
}
catch {
    [Console]::Error.WriteLine('overlay error: ' + $_.Exception.Message)
    exit 1
}
