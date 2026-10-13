# 仅在一次性 GitHub Windows 机器安装固定 SDK；默认 SDK 不能代替 Chromium 基线。
param([Parameter(Mandatory = $true)][string]$Evidence)
$ErrorActionPreference = 'Stop'
if ($env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:RUNNER_OS -ne 'Windows') {
    throw 'SDK 安装仅允许一次性 GitHub 托管 Windows runner'
}
New-Item -ItemType Directory -Force -Path $Evidence | Out-Null
$Evidence = (Resolve-Path $Evidence).Path
$spec = Get-Content (Join-Path $PSScriptRoot 'windows_sdk.json') -Raw | ConvertFrom-Json
$installer = Join-Path $env:RUNNER_TEMP 'aegis-winsdksetup.exe'
$receipt = @{status = 'failed'; sdkVersion = $spec.version; packageVersion = $spec.packageVersion; url = $spec.url}
try {
    Invoke-WebRequest -Uri $spec.url -OutFile $installer
    $receipt.sha256 = (Get-FileHash $installer -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($receipt.sha256 -ne $spec.sha256) { throw 'SDK 安装器摘要不匹配' }
    $signature = Get-AuthenticodeSignature $installer
    $receipt.signatureStatus = [string]$signature.Status
    $receipt.signer = $signature.SignerCertificate.Subject
    if ($signature.Status -ne 'Valid' -or $receipt.signer -notmatch 'O=Microsoft Corporation') {
        throw 'SDK 安装器的微软签名无效'
    }
    $arguments = '/quiet /norestart /features OptionId.DesktopCPPx86 OptionId.DesktopCPPx64 OptionId.UWPCPP OptionId.SigningTools OptionId.WindowsDesktopDebuggers /log "' + (Join-Path $Evidence 'install.log') + '"'
    $process = Start-Process -FilePath $installer -ArgumentList $arguments -Wait -PassThru
    $receipt.exitCode = $process.ExitCode
    if ($process.ExitCode -notin @(0, 3010)) { throw "SDK 安装失败：$($process.ExitCode)" }
    $receipt.status = 'installed_pending_validation'
} catch {
    $receipt.error = $_.Exception.Message
    throw
} finally {
    $receipt | ConvertTo-Json | Set-Content (Join-Path $Evidence 'install-result.json') -Encoding utf8
}
