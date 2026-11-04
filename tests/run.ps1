# Run the offline cc-ai test suite in headless CraftOS-PC.
# Usage: .\tests\run.ps1 [-Suite test_ai] [-Emulator path\to\CraftOS-PC_console.exe]
param(
  [string]$Suite = "",
  [string]$Emulator = "CraftOS-PC_console.exe"
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$data = Join-Path ([System.IO.Path]::GetTempPath()) "cc-ai-test-data"
$results = Join-Path $data "computer\0\cc-ai-test-results.txt"

New-Item -ItemType Directory -Force $data | Out-Null
if (Test-Path $results) { Remove-Item $results }

$emuArgs = @(
  "--headless",
  "-d", $data,
  "--mount-ro", "/cc-ai=$repo",
  "--script", (Join-Path $repo "tests\emulator-startup.lua")
)
if ($Suite -ne "") { $emuArgs += @("--args", $Suite) }

# Headless output is a raw screen dump; the suite writes its results to a file
& $Emulator @emuArgs | Out-Null

if (-not (Test-Path $results)) {
  Write-Error "No results file: the emulator did not run the suite."
}
$text = Get-Content $results -Raw
Write-Output $text
if ($text -match "FAILED|runner crashed") { exit 1 }
exit 0
