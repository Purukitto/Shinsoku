# Launch the screenshot harness: the real Shinsoku window with deterministic
# mock data. Navigate, then press F1-F6 to write docs/screenshots/<name>.png.
#
#   ./tool/screenshots.ps1
#
$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$shotDir = Join-Path $repo 'docs\screenshots'

if (-not (Test-Path $shotDir)) {
    New-Item -ItemType Directory -Force -Path $shotDir | Out-Null
}

Write-Host "Screenshots -> $shotDir" -ForegroundColor Cyan
Write-Host 'Keys: F1 hero  F2 active  F3 detail  F4 add  F5 settings  F6 completed' -ForegroundColor DarkGray

Push-Location (Join-Path $repo 'app')
try {
    flutter run -t lib/main_screenshots.dart -d windows --release --dart-define="SHOT_DIR=$shotDir"
}
finally {
    Pop-Location
}
