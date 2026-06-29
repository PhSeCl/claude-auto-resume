$ErrorActionPreference = 'Stop'

function Load-ScriptFunctions {
  param([string]$Path)

  $raw = Get-Content -Raw -LiteralPath $Path
  $parts = $raw -split "(?ms)^try\s*\{", 2
  if ($parts.Count -lt 1 -or [string]::IsNullOrWhiteSpace($parts[0])) {
    throw "Failed to isolate function definitions from $Path"
  }

  $functionsOnly = [regex]::Replace($parts[0], '(?m)^function\s+([A-Za-z0-9_-]+)\s*\{', 'function script:$1 {')
  Invoke-Expression $functionsOnly
}

function Get-ExpectedResumeTimestamp {
  param(
    [System.TimeZoneInfo]$TimeZone,
    [int]$Hour24,
    [int]$Minute
  )

  $nowUtc = [DateTimeOffset]::UtcNow
  $nowInZone = [System.TimeZoneInfo]::ConvertTime($nowUtc, $TimeZone)
  $targetDate = $nowInZone.Date
  $targetTimeOfDay = [TimeSpan]::FromHours($Hour24) + [TimeSpan]::FromMinutes($Minute)

  if ($nowInZone.TimeOfDay -gt $targetTimeOfDay) {
    $targetDate = $targetDate.AddDays(1)
  }

  $targetLocalTime = [datetime]::SpecifyKind(
    [datetime]::new($targetDate.Year, $targetDate.Month, $targetDate.Day, $Hour24, $Minute, 0),
    [DateTimeKind]::Unspecified
  )

  $targetUtc = [System.TimeZoneInfo]::ConvertTimeToUtc($targetLocalTime, $TimeZone)
  return [DateTimeOffset]::new($targetUtc).ToUnixTimeSeconds()
}

function Assert-Equal {
  param(
    [string]$Name,
    $Actual,
    $Expected
  )

  if ($Actual -ne $Expected) {
    throw "$Name failed. Expected '$Expected' but got '$Actual'."
  }
}

function Assert-SequenceEqual {
  param(
    [string]$Name,
    [string[]]$Actual,
    [string[]]$Expected
  )

  $actualJoined = [string]::Join("`0", $Actual)
  $expectedJoined = [string]::Join("`0", $Expected)
  if ($actualJoined -ne $expectedJoined) {
    throw "$Name failed. Expected '$($Expected -join ' ')' but got '$($Actual -join ' ')'."
  }
}

$scriptPath = Join-Path $PSScriptRoot 'claude-auto-resume.ps1'
Load-ScriptFunctions -Path $scriptPath

$cases = @(
  @{
    Name = 'new format respects explicit timezone'
    Message = "You've hit your limit resets 2am (Europe/Paris)"
    TimeZone = [System.TimeZoneInfo]::FindSystemTimeZoneById('Europe/Paris')
    Hour24 = 2
    Minute = 0
  },
  @{
    Name = 'new format without timezone uses local zone'
    Message = '5-hour limit reached resets 11:30pm'
    TimeZone = [System.TimeZoneInfo]::Local
    Hour24 = 23
    Minute = 30
  }
)

$passed = 0
foreach ($case in $cases) {
  $actual = Extract-NewFormatTimestamp -ClaudeOutput $case.Message
  $expected = Get-ExpectedResumeTimestamp -TimeZone $case.TimeZone -Hour24 $case.Hour24 -Minute $case.Minute
  Assert-Equal -Name $case.Name -Actual $actual -Expected $expected
  Write-Host "PASS: $($case.Name)"
  $passed++
}

function Assert-DateTimeEqual {
  param(
    [string]$Name,
    [datetime]$Actual,
    [datetime]$Expected
  )

  if ($Actual -ne $Expected) {
    throw "$Name failed. Expected '$($Expected.ToString('yyyy-MM-dd HH:mm:ss'))' but got '$($Actual.ToString('yyyy-MM-dd HH:mm:ss'))'."
  }
}

$paris = [System.TimeZoneInfo]::FindSystemTimeZoneById('Europe/Paris')

$ambiguousReference = [DateTimeOffset]::new(2026, 10, 24, 23, 30, 0, [TimeSpan]::Zero)
$ambiguousActual = Get-NextResetUtcTime -TimeZone $paris -Hour 2 -Minute 0 -ReferenceUtc $ambiguousReference
$ambiguousExpected = [datetime]::SpecifyKind([datetime]'2026-10-25 00:00:00', [DateTimeKind]::Utc)
Assert-DateTimeEqual -Name 'ambiguous 2am chooses first upcoming occurrence' -Actual $ambiguousActual -Expected $ambiguousExpected
Write-Host 'PASS: ambiguous 2am chooses first upcoming occurrence'
$passed++

$invalidReference = [DateTimeOffset]::new(2026, 3, 28, 23, 30, 0, [TimeSpan]::Zero)
$invalidActual = Get-NextResetUtcTime -TimeZone $paris -Hour 2 -Minute 30 -ReferenceUtc $invalidReference
$invalidExpected = [datetime]::SpecifyKind([datetime]'2026-03-29 01:00:00', [DateTimeKind]::Utc)
Assert-DateTimeEqual -Name 'invalid 2:30am advances to next valid instant' -Actual $invalidActual -Expected $invalidExpected
Write-Host 'PASS: invalid 2:30am advances to next valid instant'
$passed++

Assert-Equal -Name 'countdown formatting floors hour/minute components' -Actual (Format-Countdown -SecondsRemaining 9357) -Expected '02:35:57'
Write-Host 'PASS: countdown formatting floors hour/minute components'
$passed++

$modernHelp = @'
  --permission-mode <mode>              Permission mode to use for the session
                                        (choices: "acceptEdits", "auto",
                                        "bypassPermissions", "default")
  --dangerously-skip-permissions        Bypass all permission checks.
'@
Assert-SequenceEqual -Name 'prefers permission mode when help supports it' -Actual (Get-PermissionBypassArguments -HelpText $modernHelp) -Expected @('--permission-mode', 'bypassPermissions')
Write-Host 'PASS: prefers permission mode when help supports it'
$passed++

$legacyHelp = @'
  --dangerously-skip-permissions        Bypass all permission checks.
'@
Assert-SequenceEqual -Name 'falls back to dangerously skip permissions flag' -Actual (Get-PermissionBypassArguments -HelpText $legacyHelp) -Expected @('--dangerously-skip-permissions')
Write-Host 'PASS: falls back to dangerously skip permissions flag'
$passed++

Assert-SequenceEqual -Name 'builds continue arguments with preferred permission mode' -Actual (Get-ClaudeResumeArguments -Prompt 'continue task' -UseContinueFlag $true -HelpText $modernHelp) -Expected @('-c', '--permission-mode', 'bypassPermissions', '-p', 'continue task')
Write-Host 'PASS: builds continue arguments with preferred permission mode'
$passed++

Assert-SequenceEqual -Name 'builds new session arguments with legacy permission flag' -Actual (Get-ClaudeResumeArguments -Prompt 'continue task' -UseContinueFlag $false -HelpText $legacyHelp) -Expected @('--dangerously-skip-permissions', '-p', 'continue task')
Write-Host 'PASS: builds new session arguments with legacy permission flag'
$passed++

function Assert-True {
  param(
    [string]$Name,
    [bool]$Condition
  )

  if (-not $Condition) {
    throw "$Name failed."
  }
}

$psi = New-ClaudeProcessStartInfo -FilePath 'claude' -Arguments @('-c', '-p', 'continue task')
Assert-Equal -Name 'process start info stores file path' -Actual $psi.FileName -Expected 'claude'
Write-Host 'PASS: process start info stores file path'
$passed++

Assert-SequenceEqual -Name 'process start info preserves argument boundaries' -Actual @($psi.ArgumentList) -Expected @('-c', '-p', 'continue task')
Write-Host 'PASS: process start info preserves argument boundaries'
$passed++

$utf8 = [System.Text.Encoding]::UTF8
Assert-True -Name 'process start info sets stdout to UTF-8' -Condition ($psi.StandardOutputEncoding.WebName -eq $utf8.WebName)
Write-Host 'PASS: process start info sets stdout to UTF-8'
$passed++

Assert-True -Name 'process start info sets stderr to UTF-8' -Condition ($psi.StandardErrorEncoding.WebName -eq $utf8.WebName)
Write-Host 'PASS: process start info sets stderr to UTF-8'
$passed++

$interactiveOutput = & {
  Invoke-InteractiveProcess -FilePath 'pwsh' -Arguments @('-NoProfile', '-Command', 'Write-Output ''继续 工作''; exit 0')
  [pscustomobject]@{
    ExitCode = $LASTEXITCODE
  }
} 2>&1
$interactiveText = (($interactiveOutput | Where-Object { $_ -is [string] }) -join '').Trim()
$interactiveExit = ($interactiveOutput | Where-Object { $_ -is [System.Management.Automation.PSCustomObject] })[0].ExitCode
Assert-Equal -Name 'interactive process preserves UTF-8 output' -Actual $interactiveText.Trim() -Expected '继续 工作'
Write-Host 'PASS: interactive process preserves UTF-8 output'
$passed++

Assert-Equal -Name 'interactive process returns exit code' -Actual $interactiveExit -Expected 0
Write-Host 'PASS: interactive process returns exit code'
$passed++

Write-Host "Passed $passed PowerShell time parsing tests."
