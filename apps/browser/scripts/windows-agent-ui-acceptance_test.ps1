param(
  [Parameter(Mandatory = $true)] [string]$NodePath,
  [Parameter(Mandatory = $true)] [string]$EvidenceDir
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$tokens = $null
$errors = $null
$source = Join-Path $root 'windows-agent-ui-acceptance.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw '验收脚本语法解析失败' }
$values = @($ast.FindAll({param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value.StartsWith('--host-resolver-rules=')}, $true))
if ($values.Count -ne 1) { throw '启动参数数量不符合预期' }
$interop = @($ast.FindAll({param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value.Contains('public static class AegisNativeWindow')}, $true))
if ($interop.Count -ne 1) { throw '窗口操作代码数量不符合预期' }
# 只编译，不调用窗口操作；可在没有交互桌面的 WinRM 会话执行。
Add-Type -TypeDefinition $interop[0].Value
if (Test-Path -LiteralPath $EvidenceDir) { throw '拒绝覆盖旧的脚本测试证据' }
New-Item -ItemType Directory -Path $EvidenceDir | Out-Null
$stdoutPath = Join-Path $EvidenceDir 'argv.json'
$stderrPath = Join-Path $EvidenceDir 'argv.err'
$p = Start-Process -FilePath $NodePath -PassThru -Wait -ArgumentList @('-e', 'process.stdout.write(JSON.stringify(process.argv.slice(1)))', '--', $values[0].Value) -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
if ($p.ExitCode -ne 0) { throw '实际进程参数验证失败' }
$actual = @([IO.File]::ReadAllText($stdoutPath) | ConvertFrom-Json)
if ($actual.Count -ne 1 -or $actual[0] -ne '--host-resolver-rules=MAP paypal-secure-login.com 127.0.0.1') { throw '含空格参数仍被拆开，不能运行界面验收' }
$report = [ordered]@{ok=$true; argument_count=$actual.Count; native_interop_compiled=$true; ui_interaction_tested=$false; script_sha256=(Get-FileHash $source -Algorithm SHA256).Hash.ToLowerInvariant()}
$json = $report | ConvertTo-Json -Compress
[IO.File]::WriteAllText((Join-Path $EvidenceDir 'report.json'), $json, [Text.UTF8Encoding]::new($false))
$json
