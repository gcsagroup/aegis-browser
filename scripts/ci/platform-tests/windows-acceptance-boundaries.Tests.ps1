# SPDX-License-Identifier: Apache-2.0

BeforeAll {
  $BrowserScripts = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\apps\browser\scripts'))
  $UiScript = Join-Path $BrowserScripts 'windows-agent-ui-acceptance.ps1'
  $HeadlessScript = Join-Path $BrowserScripts 'windows-protection-headless-acceptance.ps1'
  $ExpectedCommit = '1111111111111111111111111111111111111111'
  $ExpectedTree = '2222222222222222222222222222222222222222'
}

Describe 'Windows Agent UI acceptance safety boundary' {
  BeforeEach {
    Mock Add-Type {}
    Mock Start-Process { throw 'Start-Process must not run in a failure-boundary test' }
    Mock Stop-Process { throw 'Stop-Process must not run in a failure-boundary test' }
    Mock Get-CimInstance { @() }
  }

  It 'throws for a missing browser before starting or controlling a process' {
    $chrome = Join-Path $TestDrive 'missing-chrome.exe'
    $fixture = Join-Path $TestDrive 'fixture.mjs'
    $source = Join-Path $TestDrive 'source'
    Mock Test-Path { $true }
    Mock Test-Path { $false } -ParameterFilter { $LiteralPath -eq $chrome }

    {
      & $UiScript -ChromePath $chrome -FixtureScript $fixture `
        -EvidenceDir (Join-Path $TestDrive 'ui-missing-chrome') `
        -SourceRoot $source -ExpectedChromiumCommit $ExpectedCommit `
        -ExpectedChromiumTree $ExpectedTree
    } | Should -Throw '*Browser does not exist*'

    Should -Invoke Start-Process -Times 0 -Exactly
    Should -Invoke Stop-Process -Times 0 -Exactly
    Should -Invoke Get-CimInstance -Times 0 -Exactly
  }

  It 'throws for a missing fixture before starting or controlling a process' {
    $chrome = Join-Path $TestDrive 'chrome.exe'
    $fixture = Join-Path $TestDrive 'missing-fixture.mjs'
    $source = Join-Path $TestDrive 'source'
    Mock Test-Path { $true }
    Mock Test-Path { $false } -ParameterFilter { $LiteralPath -eq $fixture }

    {
      & $UiScript -ChromePath $chrome -FixtureScript $fixture `
        -EvidenceDir (Join-Path $TestDrive 'ui-missing-fixture') `
        -SourceRoot $source -ExpectedChromiumCommit $ExpectedCommit `
        -ExpectedChromiumTree $ExpectedTree
    } | Should -Throw '*Agent fixture does not exist*'

    Should -Invoke Start-Process -Times 0 -Exactly
    Should -Invoke Stop-Process -Times 0 -Exactly
    Should -Invoke Get-CimInstance -Times 0 -Exactly
  }
}

Describe 'Windows headless protection acceptance safety boundary' {
  BeforeEach {
    Mock Start-Process { throw 'Start-Process must not run in a failure-boundary test' }
    Mock Stop-Process { throw 'Stop-Process must not run in a failure-boundary test' }
    Mock Get-CimInstance { @() }
  }

  It 'refuses to overwrite an existing evidence directory without launching anything' {
    $evidence = Join-Path $TestDrive 'existing-evidence'
    Mock Test-Path { $true } -ParameterFilter { $Path -eq $evidence }

    {
      & $HeadlessScript -NodePath 'node.exe' -ChromePath 'missing-chrome.exe' `
        -SourceRoot (Join-Path $TestDrive 'source') -EvidenceDir $evidence `
        -ArtifactHashesJson (Join-Path $TestDrive 'hashes.json') `
        -ExpectedChromiumCommit $ExpectedCommit -ExpectedChromiumTree $ExpectedTree
    } | Should -Throw '*拒绝覆盖既有验收目录*'

    Should -Invoke Start-Process -Times 0 -Exactly
    Should -Invoke Stop-Process -Times 0 -Exactly
    Should -Invoke Get-CimInstance -Times 0 -Exactly
  }

  It 'records a completed failed result for a mismatched mocked git SHA' {
    $evidence = Join-Path $TestDrive 'sha-mismatch-evidence'
    Mock git.exe { 'ffffffffffffffffffffffffffffffffffffffff' }

    & $HeadlessScript -NodePath 'node.exe' -ChromePath 'missing-chrome.exe' `
      -SourceRoot (Join-Path $TestDrive 'source') -EvidenceDir $evidence `
      -ArtifactHashesJson (Join-Path $TestDrive 'hashes.json') `
      -ExpectedChromiumCommit $ExpectedCommit -ExpectedChromiumTree $ExpectedTree

    $LASTEXITCODE | Should -Be 1
    $statusPath = Join-Path $evidence 'status.json'
    Test-Path -LiteralPath $statusPath -PathType Leaf | Should -BeTrue
    $status = [IO.File]::ReadAllText($statusPath) | ConvertFrom-Json
    $status.completed | Should -BeTrue
    $status.passed | Should -BeFalse
    $status.ui_interaction_tested | Should -BeFalse
    $status.error | Should -Be '源码提交不匹配'
    Should -Invoke git.exe -Times 1 -Exactly
    Should -Invoke Get-CimInstance -Times 1 -Exactly
    Should -Invoke Start-Process -Times 0 -Exactly
    Should -Invoke Stop-Process -Times 0 -Exactly
  }
}
