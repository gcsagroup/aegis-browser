param(
  [Parameter(Mandatory = $true)]
  [string]$ChromePath,
  [Parameter(Mandatory = $true)]
  [string]$FixtureScript,
  [Parameter(Mandatory = $true)]
  [string]$EvidenceDir,
  [Parameter(Mandatory = $true)]
  [string]$SourceRoot,
  [Parameter(Mandatory = $true)]
  [ValidatePattern('^[0-9a-f]{40}$')]
  [string]$ExpectedChromiumCommit,
  [Parameter(Mandatory = $true)]
  [ValidatePattern('^[0-9a-f]{40}$')]
  [string]$ExpectedChromiumTree,
  [int]$FixturePort = 18765,
  [int]$TimeoutSeconds = 90
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class AegisNativeWindow {
  [DllImport("user32.dll", SetLastError = true)]
  private static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
  [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  private static extern bool GetUserObjectInformation(IntPtr handle, int index,
      StringBuilder value, int capacity, out int needed);
  [DllImport("user32.dll")]
  private static extern bool CloseDesktop(IntPtr handle);
  public static bool HasInteractiveInputDesktop() {
    IntPtr desktop = OpenInputDesktop(0, false, 0x0001);
    if (desktop == IntPtr.Zero) return false;
    try {
      var name = new StringBuilder(256);
      int needed;
      return GetUserObjectInformation(desktop, 2, name, name.Capacity * 2, out needed) &&
          String.Equals(name.ToString(), "Default", StringComparison.OrdinalIgnoreCase);
    } finally {
      CloseDesktop(desktop);
    }
  }
  [DllImport("user32.dll")]
  public static extern bool ShowWindow(IntPtr hWnd, int command);
  [DllImport("user32.dll")]
  public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")]
  public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")]
  private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
  [DllImport("kernel32.dll")]
  private static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")]
  private static extern bool AttachThreadInput(uint from, uint to, bool attach);
  [DllImport("user32.dll")]
  private static extern bool BringWindowToTop(IntPtr hWnd);
  [DllImport("user32.dll")]
  private static extern IntPtr SetActiveWindow(IntPtr hWnd);
  [DllImport("user32.dll")]
  private static extern IntPtr SetFocus(IntPtr hWnd);
  [DllImport("user32.dll")]
  private static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")]
  private static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
  public static bool FocusOwnedWindow(IntPtr window) {
    uint ignored;
    uint current = GetCurrentThreadId();
    uint target = GetWindowThreadProcessId(window, out ignored);
    uint foreground = GetWindowThreadProcessId(GetForegroundWindow(), out ignored);
    bool targetAttached = current != target && AttachThreadInput(current, target, true);
    bool foregroundAttached = foreground != 0 && foreground != current &&
        foreground != target && AttachThreadInput(current, foreground, true);
    try {
      ShowWindow(window, 9);
      BringWindowToTop(window);
      SetForegroundWindow(window);
      SetActiveWindow(window);
      SetFocus(window);
      return GetForegroundWindow() == window;
    } finally {
      if (foregroundAttached) AttachThreadInput(current, foreground, false);
      if (targetAttached) AttachThreadInput(current, target, false);
    }
  }
  public static void ClickPoint(int x, int y) {
    SetCursorPos(x, y);
    mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
    mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
  }
}
'@

$script:BrowserProcessId = 0
$script:BrowserWindow = $null

function Assert-Condition {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) {
    throw $Message
  }
}

function Wait-Until {
  param(
    [scriptblock]$Condition,
    [string]$Description,
    [int]$Seconds = $TimeoutSeconds
  )
  $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
  do {
    $value = & $Condition
    if ($null -ne $value -and $value -ne $false) {
      return $value
    }
    Start-Sleep -Milliseconds 250
  } while ([DateTime]::UtcNow -lt $deadline)
  throw "Timed out waiting for $Description"
}

function Focus-BrowserWindow {
  # 只操作本轮创建的浏览器窗口；不关闭或授权其他程序的安全弹窗。
  Wait-Until {
    Assert-Condition ([AegisNativeWindow]::HasInteractiveInputDesktop()) `
        'The input desktop is locked or protected. Unlock it or dismiss the security prompt manually.'
    Assert-Condition ($null -ne $script:BrowserWindow) 'The browser window is unavailable'
    Assert-Condition ($script:BrowserWindow.Current.ProcessId -eq $script:BrowserProcessId) `
        'Refusing to focus a window outside this acceptance run'
    $windowHandle = [IntPtr]$script:BrowserWindow.Current.NativeWindowHandle
    if ($windowHandle -eq [IntPtr]::Zero) { return $false }
    [AegisNativeWindow]::FocusOwnedWindow($windowHandle) | Out-Null
    return [AegisNativeWindow]::GetForegroundWindow() -eq $windowHandle
  } 'the owned browser window to receive foreground focus' 10 | Out-Null
}

function Get-DesktopElements {
  $root = [System.Windows.Automation.AutomationElement]::RootElement
  if ($script:BrowserProcessId -le 0) {
    return @()
  }
  $condition = [System.Windows.Automation.PropertyCondition]::new(
      [System.Windows.Automation.AutomationElement]::ProcessIdProperty,
      $script:BrowserProcessId)
  return $root.FindAll(
      [System.Windows.Automation.TreeScope]::Descendants,
      $condition)
}

function Get-ElementRecords {
  $records = [System.Collections.Generic.List[object]]::new()
  foreach ($item in (Get-DesktopElements)) {
    $name = $item.Current.Name
    $automationId = $item.Current.AutomationId
    if ([string]::IsNullOrWhiteSpace($name) -and
        [string]::IsNullOrWhiteSpace($automationId)) {
      continue
    }
    $records.Add([ordered]@{
      name = $name
      automation_id = $automationId
      control_type = $item.Current.ControlType.ProgrammaticName
      enabled = $item.Current.IsEnabled
      offscreen = $item.Current.IsOffscreen
      process_id = $item.Current.ProcessId
    })
    if ($records.Count -ge 2000) {
      break
    }
  }
  return $records
}

function Save-UiaSnapshot {
  param([string]$Name)
  $path = Join-Path $EvidenceDir "$Name-uia.json"
  Get-ElementRecords | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $path -Encoding utf8
  return $path
}

function Find-ElementByName {
  param([string[]]$Names)
  $offscreenMatch = $null
  foreach ($item in (Get-DesktopElements)) {
    if ($Names -notcontains $item.Current.Name) {
      continue
    }
    if (-not $item.Current.IsOffscreen) {
      return $item
    }
    if ($null -eq $offscreenMatch) {
      $offscreenMatch = $item
    }
  }
  return $offscreenMatch
}

function Find-ElementByAutomationId {
  param([string]$AutomationId, [switch]$VisibleOnly)
  foreach ($item in (Get-DesktopElements)) {
    if ($item.Current.AutomationId -eq $AutomationId -and
        (-not $VisibleOnly -or -not $item.Current.IsOffscreen)) {
      return $item
    }
  }
  return $null
}

function Show-Element {
  param([System.Windows.Automation.AutomationElement]$Element)
  if (-not $Element.Current.IsOffscreen) {
    return
  }
  $pattern = $null
  if ($Element.TryGetCurrentPattern(
      [System.Windows.Automation.ScrollItemPattern]::Pattern,
      [ref]$pattern)) {
    ([System.Windows.Automation.ScrollItemPattern]$pattern).ScrollIntoView()
    Start-Sleep -Milliseconds 250
  }
}

function Click-ElementBounds {
  param([System.Windows.Automation.AutomationElement]$Element)
  Assert-Condition ($Element.Current.ProcessId -eq $script:BrowserProcessId) `
      'Refusing a click outside the test browser'
  Show-Element $Element
  Focus-BrowserWindow
  $bounds = $Element.Current.BoundingRectangle
  Assert-Condition (-not $Element.Current.IsOffscreen -and
      $Element.Current.IsEnabled -and $bounds.Width -gt 1 -and $bounds.Height -gt 1) `
      "Control is not visibly clickable: $($Element.Current.Name)"
  [AegisNativeWindow]::ClickPoint(
      [int]($bounds.Left + $bounds.Width / 2),
      [int]($bounds.Top + $bounds.Height / 2))
  Start-Sleep -Milliseconds 150
}

function Invoke-Element {
  param([System.Windows.Automation.AutomationElement]$Element)
  Show-Element $Element
  $pattern = $null
  if ($Element.TryGetCurrentPattern(
      [System.Windows.Automation.InvokePattern]::Pattern,
      [ref]$pattern)) {
    ([System.Windows.Automation.InvokePattern]$pattern).Invoke()
    return
  }
  if ($Element.TryGetCurrentPattern(
      [System.Windows.Automation.SelectionItemPattern]::Pattern,
      [ref]$pattern)) {
    ([System.Windows.Automation.SelectionItemPattern]$pattern).Select()
    return
  }
  Click-ElementBounds $Element
}

function Set-ElementValue {
  param(
    [System.Windows.Automation.AutomationElement]$Element,
    [string]$Value
  )
  Click-ElementBounds $Element
  [System.Windows.Forms.Clipboard]::SetText($Value)
  [System.Windows.Forms.SendKeys]::SendWait('^a')
  [System.Windows.Forms.SendKeys]::SendWait('^v')
  Start-Sleep -Milliseconds 300
  $pattern = $null
  if ($Element.TryGetCurrentPattern(
      [System.Windows.Automation.ValuePattern]::Pattern,
      [ref]$pattern)) {
    Assert-Condition (([System.Windows.Automation.ValuePattern]$pattern).Current.Value -eq $Value) `
        'The input did not accept the exact requested text'
  }
}

function Open-BrowserUrl {
  param([string]$Url)
  Focus-BrowserWindow
  [System.Windows.Forms.SendKeys]::SendWait('^l')
  [System.Windows.Forms.Clipboard]::SetText($Url)
  [System.Windows.Forms.SendKeys]::SendWait('^v')
  [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
}

function Read-CurrentUrl {
  Focus-BrowserWindow
  [System.Windows.Forms.SendKeys]::SendWait('^l')
  [System.Windows.Forms.SendKeys]::SendWait('^c')
  Start-Sleep -Milliseconds 250
  return [System.Windows.Forms.Clipboard]::GetText()
}

function Get-FixtureRequests {
  return Invoke-RestMethod -Uri `
      "http://127.0.0.1:$FixturePort/evidence/requests"
}

function Get-ProviderRequestCount {
  $current = Get-FixtureRequests
  return @($current.requests | Where-Object {
      $_.path -eq '/provider/v1/responses'
    }).Count
}

function Wait-AgentTaskComplete {
  param(
    [int]$BeforeProviderCount,
    [int]$MinimumNewRequests,
    [string]$Description,
    [string]$CompletionName = 'Task complete'
  )
  Wait-Until {
    (Get-ProviderRequestCount) -ge `
        ($BeforeProviderCount + $MinimumNewRequests)
  } "$Description model calls" $TimeoutSeconds | Out-Null
  $completion = Wait-Until {
    $names = @(Get-ElementRecords | ForEach-Object { $_.name })
    if ($names -contains $CompletionName) {
      return Find-ElementByName @($CompletionName)
    }
    return $null
  } $Description $TimeoutSeconds
  if ($null -ne $completion) {
    Show-Element $completion
  }
}

function Assert-NewProviderTools {
  param(
    [int]$BeforeProviderCount,
    [string[]]$ExpectedTools,
    [string]$Description
  )
  $current = Get-FixtureRequests
  $providerRequests = @($current.requests | Where-Object {
      $_.path -eq '/provider/v1/responses'
    })
  $actual = @($providerRequests | Select-Object -Skip $BeforeProviderCount |
      ForEach-Object {
        if ($null -ne $_.requested_tools -and $_.requested_tools.Count -gt 0) {
          [string]$_.requested_tools[0]
        }
      })
  $cursor = 0
  foreach ($expected in $ExpectedTools) {
    $found = -1
    for ($index = $cursor; $index -lt $actual.Count; $index += 1) {
      if ($actual[$index] -eq $expected) {
        $found = $index
        break
      }
    }
    Assert-Condition ($found -ge 0) `
        "$Description did not request $expected in order"
    $cursor = $found + 1
  }
  return $actual
}

function Save-Screenshot {
  param([string]$Name)
  Assert-Condition ($null -ne $script:BrowserWindow) `
      'The GCSA Aegis window is unavailable for a scoped screenshot'
  $rawBounds = $script:BrowserWindow.Current.BoundingRectangle
  $virtual = [System.Windows.Forms.SystemInformation]::VirtualScreen
  $left = [Math]::Max([int]$rawBounds.Left, $virtual.Left)
  $top = [Math]::Max([int]$rawBounds.Top, $virtual.Top)
  $right = [Math]::Min([int]$rawBounds.Right, $virtual.Right)
  $bottom = [Math]::Min([int]$rawBounds.Bottom, $virtual.Bottom)
  $bounds = [System.Drawing.Rectangle]::FromLTRB($left, $top, $right, $bottom)
  Assert-Condition ($bounds.Width -gt 0 -and $bounds.Height -gt 0) `
      'The current Windows session has no visible desktop'
  $bitmap = [System.Drawing.Bitmap]::new($bounds.Width, $bounds.Height)
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  try {
    $graphics.CopyFromScreen(
        $left, $top, 0, 0, $bitmap.Size,
        [System.Drawing.CopyPixelOperation]::SourceCopy)
    $path = Join-Path $EvidenceDir "$Name.png"
    $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    return $path
  } finally {
    $graphics.Dispose()
    $bitmap.Dispose()
  }
}

function Stop-ProcessTree {
  param([System.Diagnostics.Process]$Process)
  if ($null -eq $Process -or $Process.HasExited) {
    return
  }
  # 子进程可能已自行退出；清理命令的附带错误不能覆盖原始验收失败。
  $cleanupPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    & taskkill.exe /PID $Process.Id /T /F *> $null
  } finally {
    $ErrorActionPreference = $cleanupPreference
  }
}

Assert-Condition (Test-Path -LiteralPath $ChromePath -PathType Leaf) `
    "Browser does not exist: $ChromePath"
Assert-Condition (Test-Path -LiteralPath $FixtureScript -PathType Leaf) `
    "Agent fixture does not exist: $FixtureScript"
Assert-Condition (Test-Path -LiteralPath (Join-Path $SourceRoot '.git')) `
    "Chromium source checkout does not exist: $SourceRoot"
Assert-Condition ([Environment]::UserInteractive) `
    'Run this script in an interactive signed-in Windows session'
$desktopBounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
Assert-Condition ($desktopBounds.Width -gt 0 -and $desktopBounds.Height -gt 0) `
    'The interactive Windows session has no usable display'
$chromeVersionInfo = (Get-Item -LiteralPath $ChromePath).VersionInfo
Assert-Condition ($chromeVersionInfo.ProductName -eq 'GCSA Aegis') `
    "Expected GCSA Aegis product metadata, got '$($chromeVersionInfo.ProductName)'"
$actualChromiumCommit = (& git.exe -C $SourceRoot rev-parse HEAD).Trim()
$actualChromiumTree = (& git.exe -C $SourceRoot rev-parse 'HEAD^{tree}').Trim()
Assert-Condition ($LASTEXITCODE -eq 0) 'Could not read Chromium source identity'
Assert-Condition ($actualChromiumCommit -eq $ExpectedChromiumCommit) `
    "Chromium commit mismatch: $actualChromiumCommit"
Assert-Condition ($actualChromiumTree -eq $ExpectedChromiumTree) `
    "Chromium tree mismatch: $actualChromiumTree"
$sourceTrackedChanges = @(
  & git.exe -C $SourceRoot status --porcelain=v1 --untracked-files=no
)
$allowedNonBuildChanges = @(
  'third_party/rust/chromium_crates_io/vendor/strsim-v0_11/.editorconfig',
  'third_party/rust/chromium_crates_io/vendor/strsim-v0_11/Cargo.toml.orig',
  'tools/gn/README.md'
)
$unexpectedTrackedChanges = @($sourceTrackedChanges | ForEach-Object {
    if ($_.Length -ge 4) { $_.Substring(3).Replace('\', '/') }
  } | Where-Object {
    $_ -and $_ -notin $allowedNonBuildChanges
  })
Assert-Condition ($unexpectedTrackedChanges.Count -eq 0) `
    "Unexpected tracked source changes: $($unexpectedTrackedChanges -join ', ')"

New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
$profileDir = Join-Path $EvidenceDir 'profile'
$defaultDir = Join-Path $profileDir 'Default'
$downloadDir = Join-Path $EvidenceDir 'downloads'
New-Item -ItemType Directory -Force -Path $defaultDir, $downloadDir | Out-Null
$readyPath = Join-Path $EvidenceDir 'fixture-ready.json'
$fixtureLog = Join-Path $EvidenceDir 'fixture-requests.jsonl'
$fixtureStdout = Join-Path $EvidenceDir 'fixture-stdout.log'
$fixtureStderr = Join-Path $EvidenceDir 'fixture-stderr.log'
$browserStdout = Join-Path $EvidenceDir 'browser-stdout.log'
$browserStderr = Join-Path $EvidenceDir 'browser-stderr.log'
Remove-Item -LiteralPath $readyPath, $fixtureLog, $fixtureStdout, `
    $fixtureStderr, $browserStdout, $browserStderr -Force `
    -ErrorAction SilentlyContinue

$preferences = [ordered]@{
  aegis = [ordered]@{
    agent_enabled = $true
    model_provider = 'openai'
    model_base_url = "http://127.0.0.1:$FixturePort/provider/v1"
    model_name = 'aegis-fixture-model'
  }
  browser = [ordered]@{check_default_browser = $false}
  download = [ordered]@{
    default_directory = $downloadDir
    prompt_for_download = $false
  }
  profile = [ordered]@{exit_type = 'Normal'}
}
$preferencesJson = $preferences | ConvertTo-Json -Depth 8 -Compress
[IO.File]::WriteAllText(
    (Join-Path $defaultDir 'Preferences'), $preferencesJson,
    [Text.UTF8Encoding]::new($false))

$fixtureProcess = $null
$browserProcess = $null
$started = [DateTime]::UtcNow
$checks = [System.Collections.Generic.List[object]]::new()
$checks.Add([ordered]@{
    name = 'interactive_desktop';
    ok = $true;
    session_id = [System.Diagnostics.Process]::GetCurrentProcess().SessionId;
    screen_width = $desktopBounds.Width;
    screen_height = $desktopBounds.Height
  })
$checks.Add([ordered]@{
    name = 'executable_product_identity';
    ok = $true;
    product_name = $chromeVersionInfo.ProductName;
    file_description = $chromeVersionInfo.FileDescription
  })
$checks.Add([ordered]@{
    name = 'source_identity_and_tracked_change_boundary';
    ok = $true;
    chromium_commit = $actualChromiumCommit;
    chromium_tree = $actualChromiumTree;
    allowed_non_build_changes = $sourceTrackedChanges
  })
try {
  $nodePath = Join-Path (Split-Path $ChromePath -Parent) `
      '..\..\third_party\node\win\node.exe'
  $nodePath = [IO.Path]::GetFullPath($nodePath)
  if (-not (Test-Path -LiteralPath $nodePath -PathType Leaf)) {
    $nodePath = (Get-Command node.exe -ErrorAction Stop).Source
  }
  $fixtureProcess = Start-Process -FilePath $nodePath -PassThru `
      -WindowStyle Hidden `
      -RedirectStandardOutput $fixtureStdout `
      -RedirectStandardError $fixtureStderr `
      -ArgumentList @(
        $FixtureScript, '--serve', '--port', $FixturePort,
        '--ready-file', $readyPath, '--log-file', $fixtureLog)
  Wait-Until { Test-Path -LiteralPath $readyPath -PathType Leaf } `
      'the local Agent fixture'
  $health = Invoke-RestMethod -Uri "http://127.0.0.1:$FixturePort/health"
  Assert-Condition ($health.ok -eq $true) 'Agent fixture health check failed'
  $checks.Add([ordered]@{name = 'fixture_health'; ok = $true})
  $bookmarkResponse = Invoke-WebRequest -UseBasicParsing -Uri `
      "http://127.0.0.1:$FixturePort/fixtures/bookmarks-500.json"
  $bookmarkData = $bookmarkResponse.Content | ConvertFrom-Json
  Assert-Condition (
      @($bookmarkData.roots.bookmark_bar.children).Count -eq 500) `
      'The deterministic bookmark fixture does not contain 500 entries'
  [IO.File]::WriteAllText(
      (Join-Path $defaultDir 'Bookmarks'), [string]$bookmarkResponse.Content,
      [Text.UTF8Encoding]::new($false))
  $checks.Add([ordered]@{
    name = 'isolated_500_bookmark_profile'; ok = $true
  })

  $arguments = @(
    "--user-data-dir=$profileDir",
    '--lang=en-US',
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-background-networking',
    '--disable-component-update',
    '--disable-default-apps',
    '--disable-domain-reliability',
    '--disable-sync',
    '--metrics-recording-only',
    '--no-pings',
    '--force-renderer-accessibility',
    '--aegis-agent-allow-local-fixture',
    '--host-resolver-rules="MAP paypal-secure-login.com 127.0.0.1"',
    '--start-maximized',
    '--enable-features=AegisAgent,AegisAgentBrowserTools,AegisAgentPageActions,AegisAgentWebMcp,AegisAgentWorkflows',
    'about:blank'
  )
  $browserProcess = Start-Process -FilePath $ChromePath -PassThru `
      -RedirectStandardOutput $browserStdout `
      -RedirectStandardError $browserStderr `
      -ArgumentList $arguments
  $script:BrowserProcessId = $browserProcess.Id

  $browserWindow = Wait-Until {
    foreach ($item in (Get-DesktopElements)) {
      if ($item.Current.ControlType -eq
          [System.Windows.Automation.ControlType]::Window -and
          $item.Current.ProcessId -eq $browserProcess.Id -and
          -not $item.Current.IsOffscreen) {
        return $item
      }
    }
    return $null
  } 'the GCSA Aegis main window'
  $script:BrowserWindow = $browserWindow
  $windowTitle = [string]$browserWindow.Current.Name
  Assert-Condition ($windowTitle -match 'GCSA Aegis') `
      "Expected a GCSA Aegis branded window, got '$windowTitle'"
  $checks.Add([ordered]@{
      name = 'branded_window_title'
      ok = $true
      value = $windowTitle
    })
  Focus-BrowserWindow
  Start-Sleep -Seconds 2
  Save-UiaSnapshot '01-browser' | Out-Null
  Save-Screenshot '01-browser' | Out-Null

  $mainMenuButton = Wait-Until {
    Find-ElementByAutomationId 'view_1007' -VisibleOnly
  } 'the visible browser main-menu button'
  Click-ElementBounds $mainMenuButton
  $agentMenuItem = Wait-Until {
    Find-ElementByName @('Aegis Agent')
  } 'the Aegis Agent app-menu entry'
  Save-UiaSnapshot '02-menu' | Out-Null
  Save-Screenshot '02-menu' | Out-Null
  $checks.Add([ordered]@{name = 'visible_agent_entry'; ok = $true})
  Click-ElementBounds $agentMenuItem

  Wait-Until {
    Find-ElementByAutomationId 'goal' -VisibleOnly
  } 'the Agent side panel'
  $commonTaskNames = @(
    'Summarize this page', 'Compare products', 'Tidy bookmarks',
    'Check dead links', 'Find download', 'Research a topic'
  )
  foreach ($taskName in $commonTaskNames) {
    Assert-Condition ($null -ne (Find-ElementByName @($taskName))) `
        "Common task is not visible: $taskName"
  }
  Assert-Condition ($null -ne (Find-ElementByName @('Automations'))) `
      'The independent Automations workspace is not visible'
  $checks.Add([ordered]@{
    name = 'common_scenarios_and_automation_entry';
    ok = $true;
    common_scenario_count = $commonTaskNames.Count
  })
  $goalElement = Wait-Until {
    Find-ElementByAutomationId 'goal'
  } 'the Agent goal input'
  $goal = "Open http://127.0.0.1:$FixturePort/research/source-01 and summarize the page"
  Set-ElementValue $goalElement $goal
  $startButton = Wait-Until {
    Find-ElementByAutomationId 'plan-button'
  } 'the Start task button'
  Assert-Condition $startButton.Current.IsEnabled 'Start task is disabled'
  Save-UiaSnapshot '03-agent-ready' | Out-Null
  Save-Screenshot '03-agent-ready' | Out-Null
  $beforeBasicProviderCount = Get-ProviderRequestCount
  Invoke-Element $startButton
  Wait-AgentTaskComplete $beforeBasicProviderCount 4 `
      'the Agent understand-plan-execute-verify flow'
  $basicTools = @(Assert-NewProviderTools $beforeBasicProviderCount @(
      'agent.submit_plan', 'page.observe',
      'page.extract', 'agent.complete') 'the basic Agent task')
  $basicUrl = Read-CurrentUrl
  [System.Windows.Forms.SendKeys]::SendWait('{ESC}')
  Assert-Condition ($basicUrl -eq "http://127.0.0.1:$FixturePort/research/source-01") `
      'The Agent did not open the explicit target URL'
  $finalRecords = Get-ElementRecords
  $finalRecords | ConvertTo-Json -Depth 4 |
      Set-Content -LiteralPath (Join-Path $EvidenceDir '04-agent-complete-uia.json') `
      -Encoding utf8
  Save-Screenshot '04-agent-complete' | Out-Null
  $finalNames = @($finalRecords | ForEach-Object { $_.name })
  Assert-Condition (
      $finalNames -contains 'Result') 'Agent did not render a result'
  $checks.Add([ordered]@{
    name = 'understand_plan_execute_verify';
    ok = $true;
    opened_url = $basicUrl;
    route = 'explicit URL; model plans and executes';
    model_tools = $basicTools
  })

  Set-ElementValue (Find-ElementByAutomationId 'goal') `
      'Find Aegis fixture research and summarize three key points'
  $beforeRoutingProviderCount = Get-ProviderRequestCount
  Invoke-Element (Find-ElementByAutomationId 'plan-button')
  Wait-AgentTaskComplete $beforeRoutingProviderCount 5 `
      'model routing from a goal without a URL'
  $routingTools = @(Assert-NewProviderTools $beforeRoutingProviderCount @(
      'agent.route_goal', 'agent.submit_plan', 'page.observe',
      'page.extract', 'agent.complete') 'model-selected local navigation')
  $routedUrl = Read-CurrentUrl
  [System.Windows.Forms.SendKeys]::SendWait('{ESC}')
  Assert-Condition ($routedUrl -eq "http://127.0.0.1:$FixturePort/research/source-01") `
      'The browser did not use the URL selected by the model fixture'
  Save-UiaSnapshot '04b-model-routed-task' | Out-Null
  Save-Screenshot '04b-model-routed-task' | Out-Null
  $checks.Add([ordered]@{
    name = 'model_routes_goal_without_explicit_url';
    ok = $true;
    opened_url = $routedUrl;
    model_tools = $routingTools;
    model_kind = 'deterministic local fixture, not Qwen'
  })

  Invoke-RestMethod -Uri `
      "http://127.0.0.1:$FixturePort/control/provider/wrong-tool-once" |
      Out-Null
  $goalElement = Wait-Until {
    Find-ElementByAutomationId 'goal'
  } 'the Agent goal input for bounded repair'
  Set-ElementValue $goalElement $goal
  $startButton = Wait-Until {
    $button = Find-ElementByAutomationId 'plan-button'
    if ($null -ne $button -and $button.Current.IsEnabled) { return $button }
    return $null
  } 'the Start task button for bounded repair'
  $beforeRepairProviderCount = Get-ProviderRequestCount
  Invoke-Element $startButton
  Wait-AgentTaskComplete $beforeRepairProviderCount 5 `
      'the one-shot model-format repair flow'
  $repairTools = @(Assert-NewProviderTools $beforeRepairProviderCount @(
      'agent.submit_plan', 'agent.submit_plan',
      'page.observe', 'page.extract', 'agent.complete') `
      'the one-shot model-format repair flow')
  Save-Screenshot '05-model-repair-complete' | Out-Null
  $checks.Add([ordered]@{
    name = 'bounded_model_tool_repair';
    ok = $true;
    model_tools = $repairTools
  })

  $goalElement = Wait-Until {
    Find-ElementByAutomationId 'goal'
  } 'the goal input for a slow navigation'
  $slowGoal = "Open http://127.0.0.1:$FixturePort/research/slow?delay_ms=35000 and summarize the page"
  Set-ElementValue $goalElement $slowGoal
  $beforeSlowProviderCount = Get-ProviderRequestCount
  $slowStarted = [DateTime]::UtcNow
  Invoke-Element (Find-ElementByAutomationId 'plan-button')
  $contextMessage = 'The task page was still loading, was closed, or left the approved ' +
      'site. Aegis stopped without reading other pages. Wait for the page ' +
      'to load or check your connection, then retry this task.'
  Wait-Until {
    Find-ElementByName @($contextMessage)
  } 'the actionable page-context error after a bounded wait' 90 | Out-Null
  $slowSeconds = ([DateTime]::UtcNow - $slowStarted).TotalSeconds
  Assert-Condition ($slowSeconds -ge 25 -and $slowSeconds -le 90) `
      'The slow-page task did not stop within its bounded navigation wait'
  $slowTools = @(Assert-NewProviderTools $beforeSlowProviderCount @(
      'agent.submit_plan') 'the slow-page task')
  Assert-Condition (@($slowTools | Where-Object {
      $_ -in @('page.extract', 'agent.complete')
    }).Count -eq 0) 'The unavailable page was read or claimed complete'
  $slowRecords = @(Get-ElementRecords)
  Assert-Condition (@($slowRecords | Where-Object {
      $_.name -eq 'Check your model connection and try again.'
    }).Count -eq 0) 'The page-context failure was incorrectly blamed on the model'
  Save-UiaSnapshot '05a-slow-page-stopped' | Out-Null
  Save-Screenshot '05a-slow-page-stopped' | Out-Null
  $checks.Add([ordered]@{
    name = 'slow_page_bounded_stop_and_actionable_error';
    ok = $true;
    elapsed_seconds = [Math]::Round($slowSeconds, 1);
    model_tools = $slowTools
  })

  Set-ElementValue (Find-ElementByAutomationId 'goal') $goal
  $beforeRecoveryProviderCount = Get-ProviderRequestCount
  $startButton = Wait-Until {
    $button = Find-ElementByAutomationId 'plan-button'
    if ($null -ne $button -and $button.Current.IsEnabled) { return $button }
    return $null
  } 'an enabled task button after a page-context failure'
  Invoke-Element $startButton
  Wait-AgentTaskComplete $beforeRecoveryProviderCount 4 `
      'a fresh task after the page-context failure'
  $recoveryTools = @(Assert-NewProviderTools $beforeRecoveryProviderCount @(
      'agent.submit_plan', 'page.observe',
      'page.extract', 'agent.complete') 'the recovered task')
  Save-Screenshot '05b-task-recovered' | Out-Null
  $checks.Add([ordered]@{
    name = 'new_task_usable_after_page_context_failure';
    ok = $true;
    model_tools = $recoveryTools
  })

  $bookmarkButton = Wait-Until {
    Find-ElementByName @('Check dead links')
  } 'the Check dead links common-task button'
  Invoke-Element $bookmarkButton
  $startButton = Wait-Until {
    $button = Find-ElementByAutomationId 'plan-button'
    if ($null -ne $button -and $button.Current.IsEnabled) { return $button }
    return $null
  } 'the Start task button for bookmark URL checks'
  $bookmarkHashBefore =
      (Get-FileHash -Algorithm SHA256 -LiteralPath `
          (Join-Path $defaultDir 'Bookmarks')).Hash.ToLowerInvariant()
  $beforeBookmarkProviderCount = Get-ProviderRequestCount
  Invoke-Element $startButton
  Wait-AgentTaskComplete $beforeBookmarkProviderCount 4 `
      'the bounded URL check in the 500-bookmark profile'
  $bookmarkTools = @(Assert-NewProviderTools $beforeBookmarkProviderCount @(
      'agent.submit_plan', 'bookmark.list',
      'bookmark.check_urls', 'agent.complete') `
      'the bounded URL check in the 500-bookmark profile')
  $bookmarkHashAfter =
      (Get-FileHash -Algorithm SHA256 -LiteralPath `
          (Join-Path $defaultDir 'Bookmarks')).Hash.ToLowerInvariant()
  Assert-Condition ($bookmarkHashBefore -eq $bookmarkHashAfter) `
      'The read-only bookmark URL check modified the bookmark file'
  Save-Screenshot '06-bookmark-url-check-complete' | Out-Null
  $checks.Add([ordered]@{
    name = 'bookmark_url_check_read_only_bounded_batch';
    ok = $true;
    bookmark_count = 500;
    checked_batch_limit = 100;
    model_tools = $bookmarkTools
  })

  $bookmarkPreviewButton = Wait-Until {
    Find-ElementByName @('Tidy bookmarks')
  } 'the Tidy bookmarks common-task button'
  Invoke-Element $bookmarkPreviewButton
  $startButton = Wait-Until {
    $button = Find-ElementByAutomationId 'plan-button'
    if ($null -ne $button -and $button.Current.IsEnabled) { return $button }
    return $null
  } 'the Start task button for bookmark category preview'
  $previewHashBefore =
      (Get-FileHash -Algorithm SHA256 -LiteralPath `
          (Join-Path $defaultDir 'Bookmarks')).Hash.ToLowerInvariant()
  $beforePreviewProviderCount = Get-ProviderRequestCount
  Invoke-Element $startButton
  Wait-AgentTaskComplete $beforePreviewProviderCount 4 `
      'the 500-bookmark category preview'
  $previewTools = @(Assert-NewProviderTools $beforePreviewProviderCount @(
      'agent.submit_plan', 'bookmark.list',
      'bookmark.plan', 'agent.complete') 'the bookmark category preview')
  $previewHashAfter =
      (Get-FileHash -Algorithm SHA256 -LiteralPath `
          (Join-Path $defaultDir 'Bookmarks')).Hash.ToLowerInvariant()
  Assert-Condition ($previewHashBefore -eq $previewHashAfter) `
      'The bookmark category preview modified the bookmark file'
  Save-Screenshot '07-bookmark-category-preview' | Out-Null
  $checks.Add([ordered]@{
    name = 'bookmark_category_preview_read_only';
    ok = $true;
    bookmark_count = 500;
    model_tools = $previewTools
  })

  Open-BrowserUrl "http://127.0.0.1:$FixturePort/download"
  Wait-Until {
    Find-ElementByName @('Aegis Fixture Software')
  } 'the official-download fixture page'
  $goalElement = Wait-Until {
    Find-ElementByAutomationId 'goal'
  } 'the Agent goal input for safe download'
  $downloadGoal = "Find and download the official Windows x64 fixture from " +
      "http://127.0.0.1:$FixturePort/download and verify it"
  Set-ElementValue $goalElement $downloadGoal
  $startButton = Wait-Until {
    $button = Find-ElementByAutomationId 'plan-button'
    if ($null -ne $button -and $button.Current.IsEnabled) { return $button }
    return $null
  } 'the Start task button for safe download'
  $beforeDownloadProviderCount = Get-ProviderRequestCount
  Invoke-Element $startButton
  $approveDownload = Wait-Until {
    $button = Find-ElementByName @('Approve exact action')
    if ($null -ne $button -and $button.Current.IsEnabled) { return $button }
    return $null
  } 'the exact download approval'
  Show-Element $approveDownload
  Save-Screenshot '08-download-exact-approval' | Out-Null
  Invoke-Element $approveDownload
  Wait-AgentTaskComplete $beforeDownloadProviderCount 6 `
      'the approved safe-download flow'
  $downloadTools = @(Assert-NewProviderTools $beforeDownloadProviderCount @(
      'agent.submit_plan', 'page.observe',
      'download.find_official', 'download.start', 'download.verify',
      'agent.complete') 'the approved safe-download flow')
  $downloadedFile = Wait-Until {
    Get-ChildItem -LiteralPath $downloadDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -ne '.crdownload' } |
        Select-Object -First 1
  } 'the downloaded fixture file'
  $downloadSha256 =
      (Get-FileHash -Algorithm SHA256 -LiteralPath $downloadedFile.FullName).Hash.ToLowerInvariant()
  Assert-Condition (
      $downloadSha256 -eq `
          'b5f502ab36c1e909f7b8b88325c292df4e20eb08956a21daf5d23d9b3aff639c') `
      'The downloaded fixture hash does not match the browser-verified hash'
  Save-Screenshot '09-download-complete' | Out-Null
  $checks.Add([ordered]@{
    name = 'safe_download_with_exact_approval';
    ok = $true;
    sha256 = $downloadSha256;
    model_tools = $downloadTools
  })

  Open-BrowserUrl "http://127.0.0.1:$FixturePort/research/source-01"
  Wait-Until {
    Find-ElementByName @('Aegis Research Source 1')
  } 'the automation target page'
  $automationTab = Wait-Until {
    Find-ElementByName @('Automations')
  } 'the independent Automations workspace'
  Invoke-Element $automationTab
  $pageUpdates = Wait-Until {
    Find-ElementByName @('Page updates')
  } 'the Page updates automation template'
  Invoke-Element $pageUpdates
  $createAutomation = Wait-Until {
    $button = Find-ElementByName @('Create automation')
    if ($null -ne $button -and $button.Current.IsEnabled) { return $button }
    return $null
  } 'the Create automation button'
  $beforeAutomationProviderCount = Get-ProviderRequestCount
  Invoke-Element $createAutomation
  Wait-AgentTaskComplete $beforeAutomationProviderCount 4 `
      'the browser-owned scheduled automation flow' `
      -CompletionName 'Waiting for next check'
  $automationTools = @(Assert-NewProviderTools $beforeAutomationProviderCount @(
      'agent.submit_plan', 'page.observe',
      'monitor.create', 'agent.complete') `
      'the browser-owned scheduled automation flow')
  Wait-Until {
    Find-ElementByName @('Page updates · Every hour')
  } 'the saved hourly automation' | Out-Null
  $pauseMonitor = Wait-Until {
    Find-ElementByName @('Pause monitor')
  } 'the Pause monitor control'
  Invoke-Element $pauseMonitor
  Wait-Until {
    Find-ElementByName @('Page updates · Paused')
  } 'the paused automation state' | Out-Null
  Assert-Condition ($null -ne (Find-ElementByName @('Paused'))) `
      '暂停后顶部状态必须明确显示已暂停'
  $resumeMonitor = Wait-Until {
    Find-ElementByName @('Resume monitor')
  } 'the Resume monitor control'
  Invoke-Element $resumeMonitor
  Wait-Until {
    Find-ElementByName @('Page updates · Every hour')
  } 'the resumed automation state' | Out-Null
  Assert-Condition ($null -ne (Find-ElementByName @('Waiting for next check'))) `
      '恢复后顶部状态必须明确显示等待定时检查'
  Save-Screenshot '10-scheduled-automation' | Out-Null
  $checks.Add([ordered]@{
    name = 'independent_scheduled_automation';
    ok = $true;
    interval_minutes = 60;
    pause_resume = $true;
    model_tools = $automationTools
  })

  $commonTasksTab = Wait-Until {
    Find-ElementByName @('Common tasks')
  } 'the Common tasks workspace'
  Invoke-Element $commonTasksTab

  Open-BrowserUrl "http://127.0.0.1:$FixturePort/sensitive"
  Wait-Until {
    Find-ElementByName @('Aegis Sensitive Form Fixture')
  } 'the sensitive local fixture page'
  $beforeSensitiveProviderCount = Get-ProviderRequestCount
  $goalElement = Wait-Until {
    Find-ElementByAutomationId 'goal'
  } 'the Agent goal input for the sensitive-page check'
  Set-ElementValue $goalElement `
      'Summarize this page without including sensitive form values'
  $startButton = Wait-Until {
    Find-ElementByAutomationId 'plan-button'
  } 'the Start task button for the sensitive-page check'
  Invoke-Element $startButton
  Wait-AgentTaskComplete $beforeSensitiveProviderCount 4 `
      'the sensitive-page Agent task'
  $sensitiveTools = @(Assert-NewProviderTools $beforeSensitiveProviderCount @(
      'agent.submit_plan', 'page.observe',
      'page.extract', 'agent.complete') 'the sensitive-page Agent task')
  Save-Screenshot '11-sensitive-page-redacted' | Out-Null
  $checks.Add([ordered]@{
    name = 'sensitive_page_agent_flow';
    ok = $true;
    model_tools = $sensitiveTools
  })

  $decoratedUrl = "http://127.0.0.1:$FixturePort/research/source-01" +
      '?keep=yes&utm_source=windows-fixture&fbclid=private-click'
  Open-BrowserUrl $decoratedUrl
  Wait-Until {
    Find-ElementByName @('Aegis Research Source 1')
  } 'the decorated local fixture page'
  $currentUrl = Read-CurrentUrl
  Assert-Condition ($currentUrl -match 'keep=yes') `
      'The expected non-tracking query parameter was removed'
  Assert-Condition ($currentUrl -notmatch 'utm_source|fbclid') `
      'Tracking parameters remain in the committed URL'
  Save-Screenshot '12-tracking-parameters-removed' | Out-Null
  $checks.Add([ordered]@{
    name = 'tracking_parameters_removed';
    ok = $true;
    committed_url = $currentUrl
  })

  Open-BrowserUrl 'chrome://aegis/'
  Wait-Until {
    Find-ElementByName @('Protection modules')
  } 'the Aegis privacy center'
  Save-Screenshot '13-privacy-center' | Out-Null
  $checks.Add([ordered]@{name = 'privacy_center_visible'; ok = $true})

  $phishingUrl = "http://paypal-secure-login.com:$FixturePort/research/source-01"
  Open-BrowserUrl $phishingUrl
  Wait-Until {
    Find-ElementByName @('Aegis detected phishing signals')
  } 'the Aegis phishing interstitial'
  Save-Screenshot '14-phishing-interstitial' | Out-Null
  $checks.Add([ordered]@{
    name = 'phishing_interstitial';
    ok = $true;
    blocked_host = 'paypal-secure-login.com'
  })

  # fixture 仍在服务时读取内存快照；持久化 JSON 会在每次请求后异步更新，
  # Windows 若恰好读到写入中间态，会把正常流程误判为 JSON 损坏。
  $fixtureEvidence = Invoke-RestMethod -Uri `
      "http://127.0.0.1:$FixturePort/evidence/requests"
  $requests = @($fixtureEvidence.requests)
  $providerRequests = @($requests | Where-Object {
      $_.path -eq '/provider/v1/responses'
    })
  Assert-Condition ($providerRequests.Count -gt 0) `
      'Model fixture received no requests'
  Assert-Condition (
      @($providerRequests | Where-Object {
          $_.forbidden_markers.Count -gt 0
        }).Count -eq 0) `
      'Model request contained a forbidden secret marker'
  Assert-Condition (
      @($providerRequests | Where-Object {
          $_.cookie_header_present -eq $true
        }).Count -eq 0) `
      'Model request unexpectedly included browser cookies'
  $checks.Add([ordered]@{
    name = 'sensitive_values_and_cookies_redacted';
    ok = $true;
    provider_request_count = $providerRequests.Count
  })

  Assert-Condition (-not $browserProcess.HasExited) `
      'GCSA Aegis exited before the acceptance flow completed'
  $crashFiles = @(Get-ChildItem -LiteralPath $profileDir -Recurse -File `
      -ErrorAction SilentlyContinue | Where-Object {
        $_.Extension -in @('.dmp', '.dump')
      })
  Assert-Condition ($crashFiles.Count -eq 0) `
      'The isolated Windows profile contains a crash dump'
  $checks.Add([ordered]@{
    name = 'browser_remained_alive_without_crash_dump';
    ok = $true;
    crash_dump_count = 0
  })

  $report = [ordered]@{
    schema_version = 3
    kind = 'aegis-windows-agent-ui-acceptance'
    ok = $true
    started_utc = $started.ToString('o')
    finished_utc = [DateTime]::UtcNow.ToString('o')
    chrome_path = $ChromePath
    chrome_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $ChromePath).Hash.ToLowerInvariant()
    chromium_commit = $actualChromiumCommit
    chromium_tree = $actualChromiumTree
    source_tracked_changes = $sourceTrackedChanges
    interactive_session_id = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
    virtual_screen = [ordered]@{
      width = $desktopBounds.Width
      height = $desktopBounds.Height
    }
    profile = 'isolated'
    fixture_origin = "http://127.0.0.1:$FixturePort"
    checks = $checks
  }
  $report | ConvertTo-Json -Depth 8 |
      Set-Content -LiteralPath (Join-Path $EvidenceDir 'report.json') -Encoding utf8
  $report | ConvertTo-Json -Depth 8
} catch {
  try { Save-UiaSnapshot 'failure' | Out-Null } catch {}
  try { Save-Screenshot 'failure' | Out-Null } catch {}
  $failure = [ordered]@{
    schema_version = 3
    kind = 'aegis-windows-agent-ui-acceptance'
    ok = $false
    started_utc = $started.ToString('o')
    finished_utc = [DateTime]::UtcNow.ToString('o')
    error = $_.Exception.Message
    checks = $checks
  }
  $failure | ConvertTo-Json -Depth 8 |
      Set-Content -LiteralPath (Join-Path $EvidenceDir 'report.json') -Encoding utf8
  throw
} finally {
  Stop-ProcessTree $browserProcess
  Stop-ProcessTree $fixtureProcess
}
