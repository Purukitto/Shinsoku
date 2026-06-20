# Assembles loadable, unpacked extensions into dist/chromium and dist/firefox
# by combining shared/ with each browser's manifest.
#
#   ./build.ps1            # build both
#   ./build.ps1 -Zip       # also produce dist/<browser>.zip

param([switch]$Zip)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$shared = Join-Path $root 'shared'
$dist = Join-Path $root 'dist'

foreach ($browser in 'chromium', 'firefox') {
  $out = Join-Path $dist $browser
  if (Test-Path $out) { Remove-Item $out -Recurse -Force }
  New-Item -ItemType Directory -Path $out -Force | Out-Null

  Copy-Item (Join-Path $shared '*') $out -Recurse -Force
  Copy-Item (Join-Path $root "$browser/manifest.json") $out -Force

  if ($Zip) {
    $zip = Join-Path $dist "$browser.zip"
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path (Join-Path $out '*') -DestinationPath $zip
    Write-Host "Built $out  (+ $zip)"
  } else {
    Write-Host "Built $out"
  }
}

Write-Host ''
Write-Host 'Load unpacked:'
Write-Host '  Chrome/Edge:  chrome://extensions -> Developer mode -> Load unpacked -> dist/chromium'
Write-Host '  Firefox:      about:debugging -> This Firefox -> Load Temporary Add-on -> dist/firefox/manifest.json'
