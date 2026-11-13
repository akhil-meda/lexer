param(
  [string]$FixtureRoot = "",
  [switch]$SkipStress
)

$ErrorActionPreference = "Stop"
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ([string]::IsNullOrWhiteSpace($FixtureRoot)) {
  $FixtureRoot = Join-Path $repositoryRoot "tests"
}
$inputDirectory = Join-Path $FixtureRoot "inputs"
$expectedDirectory = Join-Path $FixtureRoot "expected_binary"
$workLibrary = Join-Path $repositoryRoot "work_beta5c"
$hardwareTokenFile = Join-Path $repositoryRoot "rtl\lexer_pkg.sv"
$softwareTokenFile = Join-Path $repositoryRoot "reference\tokens.hpp"

function Get-TokenMap {
  param(
    [string]$Path,
    [string]$Pattern
  )
  $tokenMap = @{}
  foreach ($line in Get-Content -LiteralPath $Path) {
    if ($line -match $Pattern) {
      $tokenMap[$Matches[1]] = [Convert]::ToInt32($Matches[2], 16)
    }
  }
  return $tokenMap
}

foreach ($requiredCommand in @("vlib", "vlog", "vsim")) {
  if (-not (Get-Command $requiredCommand -ErrorAction SilentlyContinue)) {
    throw "Required ModelSim command '$requiredCommand' was not found on PATH."
  }
}

if (-not (Test-Path -LiteralPath $inputDirectory -PathType Container)) {
  throw "Fixture input directory not found: $inputDirectory"
}
if (-not (Test-Path -LiteralPath $expectedDirectory -PathType Container)) {
  throw "Fixture expected-output directory not found: $expectedDirectory"
}
if (-not (Test-Path -LiteralPath $softwareTokenFile -PathType Leaf)) {
  throw "Software token definition not found: $softwareTokenFile"
}

$hardwareTokens = Get-TokenMap $hardwareTokenFile "TOK_([A-Z_]+)\s*=\s*8'h([0-9a-fA-F]{2})"
$softwareTokens = Get-TokenMap $softwareTokenFile "^\s*([A-Z_]+)\s*=\s*0x([0-9a-fA-F]{2})"
if ($hardwareTokens.Count -ne $softwareTokens.Count) {
  throw "Token ABI entry-count mismatch: hardware=$($hardwareTokens.Count) software=$($softwareTokens.Count)"
}
foreach ($tokenName in $softwareTokens.Keys) {
  if (-not $hardwareTokens.ContainsKey($tokenName) -or
      $hardwareTokens[$tokenName] -ne $softwareTokens[$tokenName]) {
    throw "Token ABI mismatch for $tokenName"
  }
}
Write-Host "Token ABI check: $($hardwareTokens.Count) entries match."

Push-Location $repositoryRoot
try {
  if (-not (Test-Path -LiteralPath $workLibrary -PathType Container)) {
    & vlib work_beta5c
    if ($LASTEXITCODE -ne 0) { throw "vlib failed with exit code $LASTEXITCODE" }
  }

  & vlog -work work_beta5c `
    rtl/lexer_pkg.sv `
    rtl/lexer_engine.sv `
    tb/lexer_engine_tb.sv `
    tb/lexer_engine_fixture_tb.sv
  if ($LASTEXITCODE -ne 0) { throw "SystemVerilog compilation failed." }

  $directedOutput = & vsim -c work_beta5c.lexer_engine_tb -do "run -all; quit -f" 2>&1
  $directedOutput | ForEach-Object { Write-Host $_ }
  if ($LASTEXITCODE -ne 0 -or
      -not ($directedOutput -match "Beta 5a/5b/5c directed tests passed") -or
      ($directedOutput -match "\*\* Error")) {
    throw "Directed regression failed."
  }

  $fixtures = Get-ChildItem -LiteralPath $inputDirectory -Filter "*.c" | Sort-Object Name
  if ($fixtures.Count -eq 0) { throw "No C fixtures found in $inputDirectory" }

  $runs = @(@{ Name = "normal"; InputGap = 0; StallPeriod = 0 })
  if (-not $SkipStress) {
    $runs += @{ Name = "stressed"; InputGap = 1; StallPeriod = 3 }
  }

  $passed = 0
  $failed = 0
  foreach ($run in $runs) {
    Write-Host "`nFixture pass: $($run.Name)"
    foreach ($fixture in $fixtures) {
      $caseName = $fixture.BaseName
      $expectedFile = Join-Path $expectedDirectory ($caseName + ".hex")
      if (-not (Test-Path -LiteralPath $expectedFile -PathType Leaf)) {
        Write-Host "FAIL $caseName - missing $expectedFile"
        $failed++
        continue
      }

      $sourceArg = $fixture.FullName.Replace("\", "/")
      $expectedArg = $expectedFile.Replace("\", "/")
      $simulationOutput = & vsim -c work_beta5c.lexer_engine_fixture_tb `
        "+CASE=$caseName" `
        "+SOURCE=$sourceArg" `
        "+EXPECTED=$expectedArg" `
        "+INPUT_GAP=$($run.InputGap)" `
        "+STALL_PERIOD=$($run.StallPeriod)" `
        -do "run -all; quit -f" 2>&1

      if ($LASTEXITCODE -eq 0 -and
          ($simulationOutput -match "BETA5C_FIXTURE_PASS $caseName") -and
          -not ($simulationOutput -match "BETA5C_FIXTURE_FAIL")) {
        $passLine = $simulationOutput | Where-Object { $_ -match "BETA5C_FIXTURE_PASS" }
        Write-Host $passLine
        $passed++
      } else {
        Write-Host "FAIL $caseName ($($run.Name))"
        $simulationOutput | ForEach-Object { Write-Host $_ }
        $failed++
      }
    }
  }

  Write-Host "`nBeta 5c fixture summary: passed=$passed failed=$failed"
  if ($failed -ne 0) { throw "$failed Beta 5c fixture run(s) failed." }
} finally {
  Pop-Location
}
