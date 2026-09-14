# SPDX-License-Identifier: Apache-2.0
param(
  [Parameter(Mandatory = $true)]
  [ValidatePattern('^[0-9a-f]{40}$')]
  [string]$TestedSha,
  [Parameter(Mandatory = $true)]
  [string]$ReportDir,
  [Parameter(Mandatory = $true)]
  [string]$PesterModulePath,
  [Parameter(Mandatory = $true)]
  [string]$PesterPackagePath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($PSVersionTable.PSEdition -ne 'Desktop' -or
    $PSVersionTable.PSVersion.Major -ne 5 -or
    $PSVersionTable.PSVersion.Minor -ne 1) {
  throw "PowerShell coverage requires Windows PowerShell 5.1; actual=$($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)"
}
$actualPowerShellHost = "$($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)"
$PesterVersion = '5.7.1'
$PesterPackageSha256 = '4a27904c6814a5fbe4758f8e49861f6a1994aee77b71165a5c43c0371ba6c580'
$PesterSourceTagCommit = 'dc45b7481fffc4f6c2ff1a74edebaad03ce1efcb'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = (& git.exe -C $scriptRoot rev-parse --show-toplevel).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Could not resolve repository root' }
$repoRoot = (Resolve-Path -LiteralPath $repoRoot).ProviderPath
$actualSha = (& git.exe -C $repoRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $actualSha -ne $TestedSha) {
  throw "Tested SHA mismatch: requested=$TestedSha actual=$actualSha"
}

function Get-CanonicalPath([string]$Path, [string]$RepositoryRoot) {
  $cursor = [IO.Path]::GetFullPath($Path)
  $missing = [Collections.Generic.List[string]]::new()
  while (-not (Test-Path -LiteralPath $cursor)) {
    $leaf = Split-Path -Leaf $cursor
    if ([string]::IsNullOrWhiteSpace($leaf)) { throw "Could not canonicalize path: $Path" }
    $missing.Insert(0, $leaf)
    $cursor = Split-Path -Parent $cursor
  }
  $existing = $cursor
  while ($true) {
    $item = Get-Item -LiteralPath $existing -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "Report path must not traverse a reparse point: $existing"
    }
    if ($existing.TrimEnd([IO.Path]::DirectorySeparatorChar) -eq
        $RepositoryRoot.TrimEnd([IO.Path]::DirectorySeparatorChar)) {
      break
    }
    $parent = Split-Path -Parent $existing
    if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $existing) { break }
    $existing = $parent
  }
  $canonical = (Resolve-Path -LiteralPath $cursor).ProviderPath
  foreach ($leaf in $missing) { $canonical = Join-Path $canonical $leaf }
  return [IO.Path]::GetFullPath($canonical)
}

$ReportDir = Get-CanonicalPath $ReportDir $repoRoot
$repoPrefix = $repoRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not $ReportDir.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
  throw "Report directory must be inside the repository: $ReportDir"
}
if (Test-Path -LiteralPath $ReportDir -PathType Leaf) {
  throw "Report path exists and is not a directory: $ReportDir"
}
if (Test-Path -LiteralPath $ReportDir -PathType Container) {
  if (@(Get-ChildItem -LiteralPath $ReportDir -Force).Count -gt 0) {
    throw "Refusing to overwrite non-empty report directory: $ReportDir"
  }
} else {
  New-Item -ItemType Directory -Path $ReportDir | Out-Null
}

$PesterPackagePath = [IO.Path]::GetFullPath($PesterPackagePath)
$actualPackageHash = (Get-FileHash -LiteralPath $PesterPackagePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualPackageHash -ne $PesterPackageSha256) {
  throw "Pester package SHA256 mismatch: expected=$PesterPackageSha256 actual=$actualPackageHash"
}
$PesterModulePath = [IO.Path]::GetFullPath($PesterModulePath)
Import-Module $PesterModulePath -Force
$module = Get-Module Pester
if ($null -eq $module -or $module.Version.ToString() -ne $PesterVersion) {
  throw "Expected Pester $PesterVersion, got $($module.Version)"
}
$moduleManifestHash = (Get-FileHash -LiteralPath $PesterModulePath -Algorithm SHA256).Hash.ToLowerInvariant()

$browserScripts = Join-Path $repoRoot 'apps\browser\scripts'
$uiSource = Join-Path $browserScripts 'windows-agent-ui-acceptance.ps1'
$headlessSource = Join-Path $browserScripts 'windows-protection-headless-acceptance.ps1'
$existingTest = Join-Path $browserScripts 'windows-agent-ui-acceptance_test.ps1'
$pesterTest = Join-Path $scriptRoot 'platform-tests\windows-acceptance-boundaries.Tests.ps1'
foreach ($requiredPath in @($uiSource, $headlessSource, $existingTest, $pesterTest)) {
  if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
    throw "Required PowerShell test or source is missing: $requiredPath"
  }
}

$node = (Get-Command node.exe -ErrorAction Stop).Source
$existingEvidence = Join-Path $ReportDir 'existing-script-test'
& $existingTest -NodePath $node -EvidenceDir $existingEvidence
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $existingEvidence 'report.json') -PathType Leaf)) {
  throw 'windows-agent-ui-acceptance_test.ps1 did not pass with evidence'
}

$configuration = New-PesterConfiguration
$configuration.Run.Path = $pesterTest
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'Detailed'
$configuration.TestResult.Enabled = $true
$configuration.TestResult.OutputFormat = 'NUnitXml'
$configuration.TestResult.OutputPath = Join-Path $ReportDir 'pester-results.xml'
$configuration.CodeCoverage.Enabled = $true
$configuration.CodeCoverage.Path = @($uiSource, $headlessSource)
$configuration.CodeCoverage.OutputFormat = 'JaCoCo'
$configuration.CodeCoverage.OutputPath = Join-Path $ReportDir 'jacoco.xml'
$result = Invoke-Pester -Configuration $configuration
if ($result.FailedCount -ne 0 -or $result.PassedCount -ne 4) {
  throw "Pester boundary tests failed: passed=$($result.PassedCount) failed=$($result.FailedCount)"
}

$jacocoPath = Join-Path $ReportDir 'jacoco.xml'
if (-not (Test-Path -LiteralPath $jacocoPath -PathType Leaf) -or (Get-Item -LiteralPath $jacocoPath).Length -eq 0) {
  throw 'Pester JaCoCo report is missing or empty'
}
[xml]$jacoco = [IO.File]::ReadAllText($jacocoPath)
$sourceFiles = @($jacoco.SelectNodes('//sourcefile'))
$expectedNames = @('windows-agent-ui-acceptance.ps1', 'windows-protection-headless-acceptance.ps1')
$reportedNames = @($sourceFiles | ForEach-Object { $_.name } | Sort-Object -Unique)
foreach ($expected in $expectedNames) {
  $reported = @($sourceFiles | Where-Object { $_.name -eq $expected })
  if ($reported.Count -ne 1) { throw "JaCoCo report does not contain exactly one production source: $expected" }
  $coveredInstructions = [int](($reported[0].SelectNodes('./line') | Measure-Object -Property ci -Sum).Sum)
  if ($coveredInstructions -le 0) { throw "JaCoCo production source has no executed instructions: $expected" }
}
if (@($reportedNames | Where-Object { $_ -like '*.Tests.ps1' -or $_ -like '*_test.ps1' }).Count -gt 0) {
  throw 'JaCoCo report contains a test harness source file'
}

$commandsAnalyzed = [int]$result.CodeCoverage.CommandsAnalyzedCount
$commandsExecuted = [int]$result.CodeCoverage.CommandsExecutedCount
if ($commandsAnalyzed -le 0 -or $commandsExecuted -le 0) {
  throw 'Pester reported empty production command coverage'
}
$coveragePercent = [Math]::Round(($commandsExecuted / $commandsAnalyzed) * 100, 2)
$coverageText = @(
  "tool=Pester $PesterVersion",
  "tested_sha=$TestedSha",
  'existing_script_test=PASS',
  "pester_tests_passed=$($result.PassedCount)/4",
  "commands_covered=$commandsExecuted",
  "commands_total=$commandsAnalyzed",
  "command_rate=$coveragePercent%"
) -join "`n"
[IO.File]::WriteAllText(
  (Join-Path $ReportDir 'coverage.txt'), $coverageText + "`n",
  [Text.UTF8Encoding]::new($false))
$jacocoSha256 = (Get-FileHash -LiteralPath $jacocoPath -Algorithm SHA256).Hash.ToLowerInvariant()
$summarySha256 = (Get-FileHash -LiteralPath (Join-Path $ReportDir 'coverage.txt') -Algorithm SHA256).Hash.ToLowerInvariant()
$testResultsSha256 = (Get-FileHash -LiteralPath (Join-Path $ReportDir 'pester-results.xml') -Algorithm SHA256).Hash.ToLowerInvariant()

$metadata = [ordered]@{
  schemaVersion = 1
  language = 'powershell'
  status = 'PASS'
  testedSha = $TestedSha
  generatedAt = [DateTime]::UtcNow.ToString('o')
  tool = [ordered]@{
    name = 'Pester'
    version = $PesterVersion
    source = 'https://www.powershellgallery.com/api/v2/package/Pester/5.7.1'
    packageSha256 = $actualPackageHash
    sourceTagCommit = $PesterSourceTagCommit
    moduleManifestSha256 = $moduleManifestHash
    host = $actualPowerShellHost
  }
  scope = [ordered]@{
    kind = 'windows-acceptance-script-safe-failure-boundaries'
    include = @(
      'apps/browser/scripts/windows-agent-ui-acceptance.ps1',
      'apps/browser/scripts/windows-protection-headless-acceptance.ps1'
    )
    exclude = @('scripts/ci/platform-tests/*.Tests.ps1')
    notMeasured = @(
      'interactive WinForms and UIAutomation acceptance',
      'real Chromium launch or browser behavior',
      'successful headless protection acceptance',
      'PowerShell scripts outside the two declared acceptance scripts'
    )
  }
  tests = @(
    [ordered]@{entry='apps/browser/scripts/windows-agent-ui-acceptance_test.ps1'; result='PASS'; kind='existing non-interactive argument and interop test'},
    [ordered]@{entry='scripts/ci/platform-tests/windows-acceptance-boundaries.Tests.ps1'; result='PASS'; cases=4; kind='mock-driven direct product script execution'}
  )
  safetyAssertions = @(
    'missing Chrome and fixture paths throw before process or window actions',
    'existing headless evidence directory is rejected',
    'mismatched mocked git SHA writes completed=true and passed=false',
    'empty mocked Get-CimInstance result never triggers Stop-Process',
    'Start-Process defaults to a throwing mock in boundary tests'
  )
  totals = [ordered]@{commands=[ordered]@{covered=$commandsExecuted; total=$commandsAnalyzed; pct=$coveragePercent}}
  reports = [ordered]@{
    jacoco = [ordered]@{path='jacoco.xml'; sha256=$jacocoSha256}
    summary = [ordered]@{path='coverage.txt'; sha256=$summarySha256}
    tests = [ordered]@{path='pester-results.xml'; sha256=$testResultsSha256}
  }
}
$metadataJson = $metadata | ConvertTo-Json -Depth 12
[IO.File]::WriteAllText(
  (Join-Path $ReportDir 'metadata.json'), $metadataJson + "`n",
  [Text.UTF8Encoding]::new($false))
foreach ($name in @('jacoco.xml', 'coverage.txt', 'metadata.json')) {
  $path = Join-Path $ReportDir $name
  if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -eq 0) {
    throw "Coverage output is missing or empty: $path"
  }
}
$metadataJson
