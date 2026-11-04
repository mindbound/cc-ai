# Run the live API checks (tests/live.lua) in headless CraftOS-PC.
# The emulator data directory holds the API keys, which you set yourself:
#   & "C:\Program Files\CraftOS-PC\CraftOS-PC.exe" -d "$env:LOCALAPPDATA\cc-ai-live"
#   (then in the emulator)  set AI_CUSTOM_API_KEY <key>
# Usage: .\tests\live.ps1 -Provider custom -Model deepseek/deepseek-v4.1-flash:thinking
param(
  [Parameter(Mandatory = $true)][string]$Provider,
  [Parameter(Mandatory = $true)][string]$Model,
  [string]$DataDir = (Join-Path $env:LOCALAPPDATA "cc-ai-live"),
  [string]$Emulator = "CraftOS-PC_console.exe"
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$results = Join-Path $DataDir "computer\0\cc-ai-live-results.txt"

New-Item -ItemType Directory -Force $DataDir | Out-Null
if (Test-Path $results) { Remove-Item $results }

& $Emulator --headless -d $DataDir --mount-ro "/cc-ai=$repo" `
  --script (Join-Path $repo "tests\emulator-live.lua") --args "$Provider $Model" | Out-Null

if (-not (Test-Path $results)) {
  Write-Error "No results file: the emulator did not run the live checks."
}
$text = Get-Content $results -Raw
Write-Output $text
if ($text -cmatch "(?m)^(   FAIL|live runner crashed)") { exit 1 }
exit 0
