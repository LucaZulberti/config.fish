# pomodoro-overlay-wsl-template.ps1
#
# Fullscreen multi-monitor Pomodoro overlay for Windows, launched from WSL
# through powershell.exe.
#
# ---------------------------------------------------------------------------
# Overview
# ---------------------------------------------------------------------------
# This script shows a fullscreen overlay on every connected Windows monitor.
# It is designed to be launched by the Pomodoro daemon running inside WSL.
#
# The implementation intentionally combines:
#   - WinForms:
#       used for the top-level fullscreen windows, monitor enumeration, focus,
#       and keyboard event fallback
#   - WebView2:
#       used for HTML/CSS rendering so text layout is flexible and emoji render
#       with browser-quality appearance instead of classic WinForms text output
#
# ---------------------------------------------------------------------------
# Placeholder values injected by the caller
# ---------------------------------------------------------------------------
# The daemon generates a temporary .ps1 file from this template and replaces:
#
#   __POMODORO_OVERLAY_TITLE__
#       Main heading shown in the overlay
#
#   __POMODORO_OVERLAY_MESSAGE__
#       Main message shown under the heading
#
#   __POMODORO_OVERLAY_DISMISS_KEY__
#       Single key name used together with Ctrl to dismiss the overlay
#       Example: "Q" means Ctrl+Q
#
#   __POMODORO_WEBVIEW2_CORE_DLL__
#       Full Windows path to Microsoft.Web.WebView2.Core.dll
#
#   __POMODORO_WEBVIEW2_WINFORMS_DLL__
#       Full Windows path to Microsoft.Web.WebView2.WinForms.dll
#
# ---------------------------------------------------------------------------
# Dismiss policy
# ---------------------------------------------------------------------------
# The overlay is intentionally hard to dismiss by accident.
#
# It supports only:
#   - Ctrl + <random letter chosen by the daemon>
#
# Clicking the overlay does nothing.
# Pressing Esc does nothing.
#
# If the dismiss chord is detected on any screen, all overlay windows are
# closed together.
#
# ---------------------------------------------------------------------------
# Error handling policy
# ---------------------------------------------------------------------------
# The script aborts on unhandled errors. The caller redirects stdout/stderr
# to an overlay log file, so failures can be diagnosed from WSL.
#
# WebView2 initialization/content failures are also surfaced through a visible
# Windows message box before the overlay exits. That is useful for direct
# troubleshooting when running the script manually.
# ---------------------------------------------------------------------------

# Stop immediately on unhandled errors so the caller receives a failing exit
# code instead of a partially initialized overlay.
$ErrorActionPreference = 'Stop'

# Load the base Windows desktop assemblies used by this script.
#
# - System.Windows.Forms:
#     forms, panels, labels, screen enumeration, key events
# - System.Drawing:
#     colors, fonts, points, sizes
Add-Type -AssemblyName System.Windows.Forms,System.Drawing

# The WebView2 assemblies are not assumed to be in the GAC or in the current
# working directory. The caller injects explicit DLL paths so the script can
# load exactly the installed copies.
$wvCoreDll = "__POMODORO_WEBVIEW2_CORE_DLL__"
$wvFormsDll = "__POMODORO_WEBVIEW2_WINFORMS_DLL__"

# Load WebView2 .NET assemblies dynamically from the injected paths.
Add-Type -Path $wvCoreDll
Add-Type -Path $wvFormsDll

# Enable modern visual styles for WinForms controls. This does not change the
# HTML rendered inside WebView2, but it keeps the host controls consistent.
[System.Windows.Forms.Application]::EnableVisualStyles()

# Read the injected user-visible content and the dismissal key.
$title = "__POMODORO_OVERLAY_TITLE__"
$message = "__POMODORO_OVERLAY_MESSAGE__"
$dismissKeyName = "__POMODORO_OVERLAY_DISMISS_KEY__"

# Convert the textual key name into the WinForms Keys enum so the form-level
# fallback handler can compare it efficiently against KeyDown events.
$dismissKey = [System.Enum]::Parse([System.Windows.Forms.Keys], $dismissKeyName, $true)

# Keep strong references to every form created by the script.
#
# This serves two purposes:
#   1. allows one dismiss action to close all overlays at once
#   2. prevents forms from being garbage-collected after local variables go
#      out of scope
$forms = New-Object System.Collections.ArrayList

function Close-AllForms {
    # Close every overlay window, ignoring secondary failures during shutdown.
    # This function is the single exit path used both by:
    #   - WinForms keyboard fallback handlers
    #   - WebView2 JavaScript -> host messages
    foreach ($f in @($forms)) {
        try {
            if ($null -ne $f) { $f.Close() }
        } catch {}
    }

    # End the WinForms message loop explicitly once forms have been closed.
    [System.Windows.Forms.Application]::ExitThread()
}

function New-PomodoroOverlayForm {
    param(
        # Target monitor descriptor from System.Windows.Forms.Screen.AllScreens.
        [System.Windows.Forms.Screen]$screen,

        # Text content already prepared by the caller.
        [string]$overlayTitle,
        [string]$overlayMessage,
        [string]$dismissKeyName
    )

    # -----------------------------------------------------------------------
    # Paths and monitor geometry
    # -----------------------------------------------------------------------
    $bounds = $screen.Bounds

    # WebView2 stores its browser-like profile/cache state inside a user data
    # folder. Using an explicit LocalAppData location is more reliable than
    # letting the runtime guess one, especially when launched from WSL.
    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    $userDataFolder = Join-Path $localAppData 'pomodoro\webview2-userdata'
    [System.IO.Directory]::CreateDirectory($userDataFolder) | Out-Null

    # -----------------------------------------------------------------------
    # Fullscreen host form
    # -----------------------------------------------------------------------
    # Each monitor gets its own borderless fullscreen form.
    $form = New-Object System.Windows.Forms.Form

    # Internal/debug title only. It is not shown in a title bar because the
    # form is borderless.
    $form.Text = 'PomodoroOverlay'

    # Remove all window chrome.
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None

    # Position the form manually on the exact target monitor.
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual

    # Keep the overlay above normal applications.
    $form.TopMost = $true

    # Do not create a taskbar button.
    $form.ShowInTaskbar = $false

    # Allow the form itself to receive key events before child controls.
    $form.KeyPreview = $true

    # The form itself is a mostly-opaque black fullscreen backdrop.
    $form.BackColor = [System.Drawing.Color]::Black
    $form.Opacity = 0.94

    # Cover exactly the monitor bounds reported by WinForms.
    $form.Location = [System.Drawing.Point]::new($bounds.X, $bounds.Y)
    $form.Size = [System.Drawing.Size]::new($bounds.Width, $bounds.Height)

    # -----------------------------------------------------------------------
    # Center card size
    # -----------------------------------------------------------------------
    # The visible content sits inside a centered card rather than spanning the
    # entire screen width. Cap the width so very wide monitors remain readable.
    $cardWidth = [Math]::Min(1200, [int]($bounds.Width * 0.72))
    $cardHeight = [Math]::Min(460, [int]($bounds.Height * 0.66))

    # -----------------------------------------------------------------------
    # Host panel
    # -----------------------------------------------------------------------
    # This panel is the centered "card" that visually contains the overlay
    # content. WebView2 fills this card entirely once initialization completes.
    $hostPanel = New-Object System.Windows.Forms.Panel
    $hostPanel.Size = [System.Drawing.Size]::new($cardWidth, $cardHeight)
    $hostPanel.BackColor = [System.Drawing.Color]::FromArgb(32, 32, 32)
    $hostPanel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

    # -----------------------------------------------------------------------
    # Loading label
    # -----------------------------------------------------------------------
    # While WebView2 starts, show a very simple WinForms label inside the card.
    # This avoids the user seeing a blank panel during startup and also keeps a
    # minimal visual hint visible if WebView2 is slow to initialize.
    $loadingLabel = New-Object System.Windows.Forms.Label
    $loadingLabel.Text = "Loading overlay...`r`nPress Ctrl+$dismissKeyName to dismiss"
    $loadingLabel.ForeColor = [System.Drawing.Color]::White
    $loadingLabel.Font = [System.Drawing.Font]::new('Segoe UI', 16, [System.Drawing.FontStyle]::Regular)
    $loadingLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $loadingLabel.Dock = [System.Windows.Forms.DockStyle]::Fill

    # -----------------------------------------------------------------------
    # WebView2 control
    # -----------------------------------------------------------------------
    # WebView2 hosts the final HTML/CSS content.
    # It starts hidden and becomes visible only after initialization succeeds.
    $webView = New-Object Microsoft.Web.WebView2.WinForms.WebView2
    $webView.Dock = [System.Windows.Forms.DockStyle]::Fill
    $webView.Margin = [System.Windows.Forms.Padding]::new(0)
    $webView.AllowExternalDrop = $false
    $webView.Visible = $false

    # Z-order matters: the last added control is visually on top.
    # We add the loading label first, then WebView2 above it.
    [void]$hostPanel.Controls.Add($loadingLabel)
    [void]$hostPanel.Controls.Add($webView)
    [void]$form.Controls.Add($hostPanel)

    # -----------------------------------------------------------------------
    # Card centering helper
    # -----------------------------------------------------------------------
    # Recompute the card position relative to the form client size.
    # This is called once initially and again on every resize event.
    $centerAction = {
        $clientW = $form.ClientSize.Width
        $clientH = $form.ClientSize.Height

        $hostPanel.Location = [System.Drawing.Point]::new(
            [int](($clientW - $hostPanel.Width) / 2),
            [int](($clientH - $hostPanel.Height) / 2)
        )
    }.GetNewClosure()

    & $centerAction

    $resizeHandler = {
        param($sender, $e)
        & $centerAction
    }.GetNewClosure()

    # -----------------------------------------------------------------------
    # Keyboard fallback on the WinForms side
    # -----------------------------------------------------------------------
    # The preferred dismiss path is JavaScript inside WebView2, but keep a
    # WinForms fallback too. If focus remains on the form or the loading label
    # instead of the browser, Ctrl+<key> should still dismiss everything.
    $keydownHandler = {
        param($sender, $e)
        if ($e.Control -and $e.KeyCode -eq $dismissKey) {
            $e.Handled = $true
            $e.SuppressKeyPress = $true
            Close-AllForms
        }
    }.GetNewClosure()

    $form.Add_Resize($resizeHandler)
    $form.Add_KeyDown($keydownHandler)
    $loadingLabel.Add_KeyDown($keydownHandler)

    # -----------------------------------------------------------------------
    # HTML escaping
    # -----------------------------------------------------------------------
    # All user-provided strings are HTML-encoded before insertion into the HTML
    # template so that characters such as <, >, and & are rendered safely as
    # text rather than being interpreted as markup.
    $safeTitle = [System.Net.WebUtility]::HtmlEncode($overlayTitle)
    $safeMessage = [System.Net.WebUtility]::HtmlEncode($overlayMessage)
    $safeDismissHint = [System.Net.WebUtility]::HtmlEncode("Press Ctrl+$dismissKeyName to dismiss on all screens")

    # JavaScript compares lowercase strings for the dismiss key.
    $dismissKeyJs = $dismissKeyName.ToLowerInvariant()

    # -----------------------------------------------------------------------
    # HTML payload rendered by WebView2
    # -----------------------------------------------------------------------
    # The entire visual overlay is expressed as HTML/CSS so typography and emoji
    # rendering are handled by the browser engine rather than WinForms text
    # controls.
    $html = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="color-scheme" content="dark">
<style>
html, body {
  margin: 0;
  width: 100%;
  height: 100%;
  background: #202020;
  color: #ffffff;
  overflow: hidden;
  font-family: "Segoe UI", "Segoe UI Emoji", sans-serif;
}
.wrap {
  box-sizing: border-box;
  width: 100%;
  height: 100%;
  padding: 28px 36px;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  text-align: center;
}
.icon {
  font-size: 76px;
  line-height: 1;
  margin-bottom: 18px;
}
.title {
  font-size: 40px;
  font-weight: 700;
  margin-bottom: 14px;
}
.body {
  font-size: 24px;
  line-height: 1.35;
  white-space: pre-line;
  max-width: 1000px;
}
.hint {
  margin-top: 20px;
  color: #cfcfcf;
  font-size: 16px;
}
</style>
</head>
<body>
  <div class="wrap" id="root" tabindex="0">
    <div class="icon">&#x1F345;</div>
    <div class="title">$safeTitle</div>
    <div class="body">$safeMessage</div>
    <div class="hint">$safeDismissHint</div>
  </div>

<script>
(function () {
  function dismissAll() {
    if (window.chrome && window.chrome.webview) {
      window.chrome.webview.postMessage("dismiss");
    }
  }

  document.addEventListener("keydown", function (ev) {
    if (ev.ctrlKey && ev.key && ev.key.toLowerCase() === "$dismissKeyJs") {
      ev.preventDefault();
      dismissAll();
    }
  });

  var root = document.getElementById("root");
  if (root) {
    root.focus();
  }
})();
</script>
</body>
</html>
"@

    # -----------------------------------------------------------------------
    # WebView2 initialization completed handler
    # -----------------------------------------------------------------------
    # This event fires after EnsureCoreWebView2Async finishes.
    # At that point the control exposes CoreWebView2 and can accept settings,
    # host-message handlers, and final content navigation.
    $initCompletedHandler = {
        param($sender, $e)

        if (-not $e.IsSuccess) {
            [System.Windows.Forms.MessageBox]::Show(
                "WebView2 initialization failed:`r`n$($e.InitializationException.Message)",
                "PomodoroOverlay",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
            Close-AllForms
            return
        }

        try {
            # Reduce the surface area of the embedded browser:
            #   - no context menu
            #   - no devtools
            #   - no zoom control
            #   - no browser-specific accelerator shortcuts
            $webView.CoreWebView2.Settings.AreDefaultContextMenusEnabled = $false
            $webView.CoreWebView2.Settings.AreDevToolsEnabled = $false
            $webView.CoreWebView2.Settings.IsZoomControlEnabled = $false
            $webView.CoreWebView2.Settings.AreBrowserAcceleratorKeysEnabled = $false

            # Bridge WebView2 -> WinForms. When JavaScript posts "dismiss",
            # close every overlay form.
            $webView.CoreWebView2.Add_WebMessageReceived({
                param($wsender, $we)
                if ($we.TryGetWebMessageAsString() -eq 'dismiss') {
                    Close-AllForms
                }
            }.GetNewClosure())

            # Hide the temporary loading label, reveal the browser, push the
            # final HTML content, and give keyboard focus to the browser.
            $loadingLabel.Visible = $false
            $webView.Visible = $true
            $webView.NavigateToString($html)
            $webView.Focus() | Out-Null
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                "WebView2 content setup failed:`r`n$($_.Exception.Message)",
                "PomodoroOverlay",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
            Close-AllForms
        }
    }.GetNewClosure()

    # -----------------------------------------------------------------------
    # Form shown handler
    # -----------------------------------------------------------------------
    # WebView2 initialization is started only once the form has actually been
    # shown. In practice this is more reliable than trying to initialize the
    # control before the host form participates in the real Win32 message loop.
    $shownHandler = {
        param($sender, $e)

        try {
            $form.Activate()

            # Create a dedicated WebView2 environment with an explicit user data
            # folder under LocalAppData. This avoids ambiguous defaults and is
            # more predictable when invoked from WSL.
            $environment = [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::CreateAsync(
                $null,
                $userDataFolder,
                $null
            ).GetAwaiter().GetResult()

            # Subscribe before initialization begins so the completion event
            # cannot be missed.
            $webView.Add_CoreWebView2InitializationCompleted($initCompletedHandler)

            # Start asynchronous initialization. The completion path continues
            # in $initCompletedHandler above.
            $null = $webView.EnsureCoreWebView2Async($environment)
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                "WebView2 startup failed:`r`n$($_.Exception.Message)",
                "PomodoroOverlay",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
            Close-AllForms
        }
    }.GetNewClosure()

    $form.Add_Shown($shownHandler)

    return $form
}

# ---------------------------------------------------------------------------
# One overlay form per physical screen
# ---------------------------------------------------------------------------
# Enumerate all monitors visible to Windows and build one fullscreen overlay
# form for each of them.
foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
    $f = New-PomodoroOverlayForm -screen $screen -overlayTitle $title -overlayMessage $message -dismissKeyName $dismissKeyName
    [void]$forms.Add($f)
}

# ---------------------------------------------------------------------------
# Show all forms, then enter the WinForms message loop
# ---------------------------------------------------------------------------
# Each form initializes its own WebView2 in its Shown handler. Application.Run
# starts the dispatcher loop required for forms, events, browser messages, and
# keyboard processing.
foreach ($f in @($forms)) {
    $f.Show()
}

[System.Windows.Forms.Application]::Run()
