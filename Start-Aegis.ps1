# Windows 本地开发入口。使用已配置的 Chromium 工具链，在子进程中同步、编译并启动。
[CmdletBinding()]
param(
    [string]$ChromiumRoot = $env:CHROMIUM_ROOT,
    [switch]$CheckOnly,
    [ValidateRange(1, 256)][int]$Jobs = 4
)

$ErrorActionPreference = 'Stop'
if (-not $ChromiumRoot) {
    $marker = Join-Path $PSScriptRoot 'apps/browser/.chromium-root'
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
        throw '请用 -ChromiumRoot 指定包含 src 的本地 Chromium 目录。'
    }
    $ChromiumRoot = (Get-Content -Raw -LiteralPath $marker).Trim()
}
$checkout = (Resolve-Path -LiteralPath $ChromiumRoot).ProviderPath
$python = Join-Path $checkout 'src/third_party/cpython3/host/bin/python.exe'
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
    $python = (Get-Command python.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
}

# 工具链脚本会替换 PATH、TEMP 等进程变量。放在独立 PowerShell 中运行，
# 让浏览器继承构建环境，同时使调用者的终端在脚本退出后继续使用原环境。
$worker = {
    param($project, $checkout, $python, $jobs, $mode)
    $ErrorActionPreference = 'Stop'
    $environmentScript = Join-Path (Split-Path -Parent $checkout) 'tools/build-env.ps1'
    if (Test-Path -LiteralPath $environmentScript -PathType Leaf) { . $environmentScript }
    $env:CHROMIUM_ROOT = $checkout
    $env:DEPOT_TOOLS_WIN_TOOLCHAIN = '0'
    $env:PYTHONUTF8 = '1'
    $arguments = @('-B', (Join-Path $project 'scripts/dev/windows_browser.py'), $checkout, '--jobs', $jobs)
    if ($mode -eq 'check') { $arguments += '--check-only' }
    & $python @arguments
    exit $LASTEXITCODE
}
$shell = if ($PSVersionTable.PSEdition -eq 'Core') {
    Join-Path $PSHOME 'pwsh.exe'
} else {
    # Windows PowerShell 5.1 会按系统代码页读取无 BOM 的本地工具链脚本，优先交给 PowerShell 7。
    $modernShell = Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($modernShell) { $modernShell.Source } else { Join-Path $PSHOME 'powershell.exe' }
}
$mode = if ($CheckOnly) { 'check' } else { 'run' }
& $shell -NoLogo -NoProfile -NonInteractive -Command $worker -Args $PSScriptRoot,$checkout,$python,$Jobs,$mode
exit $LASTEXITCODE
