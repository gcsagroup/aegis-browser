param(
  [Parameter(Mandatory=$true)][string]$NodePath,
  [Parameter(Mandatory=$true)][string]$ChromePath,
  [Parameter(Mandatory=$true)][string]$SourceRoot,
  [Parameter(Mandatory=$true)][string]$EvidenceDir,
  [Parameter(Mandatory=$true)][string]$ArtifactHashesJson,
  [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-f]{40}$')][string]$ExpectedChromiumCommit,
  [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-f]{40}$')][string]$ExpectedChromiumTree
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (Test-Path $EvidenceDir) { throw '拒绝覆盖既有验收目录' }
New-Item -ItemType Directory -Path $EvidenceDir | Out-Null
$statusPath = Join-Path $EvidenceDir 'status.json'
$status = [ordered]@{completed=$false; passed=$false; ui_interaction_tested=$false; started_utc=[DateTime]::UtcNow.ToString('o'); error=$null; checks=@(); artifact_hashes=@(); process_leaks=@()}
$fixture = $null
$profiles = [Collections.Generic.List[string]]::new()
function Save-State { [IO.File]::WriteAllText($statusPath, ($status | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false)) }
function Assert-Condition([bool]$ok, [string]$message) { if (-not $ok) { throw $message } }
function Quote-Arguments([string[]]$values) { return (($values | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' }) -join ' ') }
function Assert-Identity {
  Assert-Condition ((& git.exe -C $SourceRoot rev-parse HEAD).Trim() -eq $ExpectedChromiumCommit) '源码提交不匹配'
  Assert-Condition ((& git.exe -C $SourceRoot rev-parse 'HEAD^{tree}').Trim() -eq $ExpectedChromiumTree) '源码树不匹配'
  $changes = @(& git.exe -C $SourceRoot status --porcelain=v1 --untracked-files=no)
  Assert-Condition ($LASTEXITCODE -eq 0) '无法检查源码状态'
  $unexpected = @($changes | Where-Object { $_.Length -ge 4 -and $_.Substring(3).Replace('\','/') -ne 'tools/gn/README.md' })
  Assert-Condition ($unexpected.Count -eq 0) '存在未批准的源码修改'
  $expected = [IO.File]::ReadAllText($ArtifactHashesJson) | ConvertFrom-Json
  $names = @('chrome.exe', 'chrome.dll', 'resources.pak', 'chrome_100_percent.pak', 'chrome_200_percent.pak')
  Assert-Condition ($expected -is [Array] -and $expected.Count -eq $names.Count) '产物清单项数不正确'
  $actual = @()
  foreach ($name in $names) {
    $path = Join-Path (Split-Path $ChromePath) $name
    $entry = @($expected | Where-Object { $_.Path -eq $path })
    Assert-Condition ($entry.Count -eq 1) '产物路径不匹配'
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash
    Assert-Condition ($hash -eq $entry[0].Hash) '产物哈希不匹配'
    $actual += [ordered]@{path=$path; sha256=$hash.ToLowerInvariant()}
  }
  $status.artifact_hashes = $actual
}
function Run-Case([string]$name, [string[]]$extra) {
  $reportPath = Join-Path $EvidenceDir ($name + '.json')
  $arguments = @((Join-Path $PSScriptRoot 'verify-multisite-runtime.mjs'), '--chromium', $ChromePath, '--headless', '--background-quiet', '--keep-profile', '--report', $reportPath) + $extra
  $child = Start-Process -FilePath $NodePath -ArgumentList (Quote-Arguments $arguments) -RedirectStandardOutput (Join-Path $EvidenceDir ($name + '.stdout.log')) -RedirectStandardError (Join-Path $EvidenceDir ($name + '.stderr.log')) -PassThru
  # 在进程退出前保留句柄，确保 PowerShell 5.1 等待后仍能取得真实退出码。
  $null = $child.Handle
  if (-not $child.WaitForExit(90000)) {
    # 只清理这个测试启动的、当前仍可证明父子关系的进程。
    $table = @(Get-CimInstance Win32_Process)
    $owned = [Collections.Generic.List[int]]::new()
    $owned.Add($child.Id)
    for ($i=0; $i -lt $owned.Count -and $i -lt 256; $i++) {
      foreach ($item in @($table | Where-Object { $_.ParentProcessId -eq $owned[$i] })) {
        if (-not $owned.Contains([int]$item.ProcessId)) { $owned.Add([int]$item.ProcessId) }
      }
    }
    for ($i=$owned.Count-1; $i -ge 0; $i--) { Stop-Process -Id $owned[$i] -ErrorAction SilentlyContinue }
    throw '无界面测试超时；已停止该次测试的进程树'
  }
  $child.Refresh()
  if (Test-Path $reportPath) {
    $result = [IO.File]::ReadAllText($reportPath) | ConvertFrom-Json
    $profiles.Add($result.profileDir)
  }
  Assert-Condition ($child.ExitCode -eq 0) ('测试未通过：' + $name)
  $result = [IO.File]::ReadAllText($reportPath) | ConvertFrom-Json
  Assert-Condition ($result.passed -and $result.results.Count -eq 1) '未取得唯一有效页面结果'
  Assert-Condition (-not $result.globalCrashpadEvidence.supported) '错误地声明 Windows 全局崩溃目录已检查'
  $status.checks += [ordered]@{name=$name; passed=$true; final_url=$result.results[0].finalUrl; title=$result.results[0].title}
  Save-State
  return $result.results[0].finalUrl
}
Save-State
try {
  Assert-Identity
  $readyPath = Join-Path $EvidenceDir 'fixture-ready.json'
  $fixtureArguments = @((Join-Path $PSScriptRoot 'verify-agent-runtime.mjs'), '--serve', '--port', '0', '--ready-file', $readyPath, '--log-file', (Join-Path $EvidenceDir 'fixture-requests.json'))
  $fixture = Start-Process -FilePath $NodePath -ArgumentList (Quote-Arguments $fixtureArguments) -RedirectStandardOutput (Join-Path $EvidenceDir 'fixture.stdout.log') -RedirectStandardError (Join-Path $EvidenceDir 'fixture.stderr.log') -PassThru
  $deadline = [DateTime]::UtcNow.AddSeconds(10)
  while (-not (Test-Path $readyPath)) {
    Assert-Condition (-not $fixture.HasExited -and [DateTime]::UtcNow -lt $deadline) '本地夹具未启动'
    Start-Sleep -Milliseconds 100
  }
  $ready = [IO.File]::ReadAllText($readyPath) | ConvertFrom-Json
  Assert-Condition ($ready.origin -match '^http://127\.0\.0\.1:[0-9]+$') '夹具不是数值回环地址'
  $on = Run-Case 'phishing-on' @('--credential-fixture', '--expect-text', 'Aegis', '--expect-aegis-interstitial')
  Assert-Condition ($on -eq 'chrome-error://chromewebdata/') '未进入真实安全拦截文档'
  $off = Run-Case 'phishing-off-control' @('--credential-fixture', '--feature-mode', 'aegis-off', '--expect-text', 'Continue')
  Assert-Condition ($off -match '^http://127\.0\.0\.1:[0-9]+/form$') '关闭保护后未显示对照表单'
  $decorated = $ready.origin + '/research/source-01?keep=yes&utm_source=windows-headless&fbclid=fixture-click'
  $clean = Run-Case 'tracking-on' @('--url', $decorated, '--expect-text', 'Source')
  Assert-Condition ($clean -eq ($ready.origin + '/research/source-01?keep=yes')) '跟踪参数未移除或正常参数被删除'
  $unchanged = Run-Case 'tracking-off-control' @('--url', $decorated, '--feature-mode', 'link-off', '--expect-text', 'Source')
  Assert-Condition ($unchanged -eq $decorated) '关闭清理后的对照地址发生变化'
  Assert-Identity
  $status.passed = $true
} catch {
  $status.error = $_.Exception.Message
} finally {
  if ($fixture -and -not $fixture.HasExited) { $fixture.Kill(); $fixture.WaitForExit() }
  # 保留测试资料与失败证据，只检查精确可执行文件和本轮 Profile 的残留。
  $leaks = @(Get-CimInstance Win32_Process | Where-Object {
    $process = $_
    $process.ExecutablePath -eq $ChromePath -and @($profiles | Where-Object { $process.CommandLine -like ('*' + $_ + '*') }).Count -gt 0
  })
  $status.process_leaks = @($leaks | Select-Object ProcessId,ParentProcessId)
  if ($leaks.Count -gt 0) {
    $status.passed = $false
    $status.error = '测试浏览器有残留进程，清理后仍计为失败'
    $leaks | ForEach-Object { Stop-Process -Id $_.ProcessId -ErrorAction SilentlyContinue }
  }
  $status.completed = $true
  $status.finished_utc = [DateTime]::UtcNow.ToString('o')
  Save-State
}
if (-not $status.passed) { exit 1 }
