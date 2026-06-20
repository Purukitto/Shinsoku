# Bump the project version everywhere and roll the changelog in one step, so the
# app, the Rust core, and both extension manifests never drift apart.
#
#   ./tool/bump-version.ps1 0.2.0
#   ./tool/bump-version.ps1 0.2.0 -Commit   # also: git commit + tag v0.2.0
#
# It updates:
#   app/pubspec.yaml            version: X.Y.Z+<build+1>
#   core/Cargo.toml             [package] version = "X.Y.Z"
#   extension/chromium|firefox/manifest.json   "version": "X.Y.Z"
#   CHANGELOG.md                [Unreleased] -> [X.Y.Z] - <today>, fresh Unreleased
param(
    [Parameter(Mandatory, Position = 0)][string]$Version,
    [switch]$Commit
)
$ErrorActionPreference = 'Stop'

if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Version must be SemVer X.Y.Z (got '$Version')."
}

$repo = Split-Path -Parent $PSScriptRoot
$tag = "v$Version"
$today = (Get-Date).ToString('yyyy-MM-dd')
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Read-Text($rel) { [System.IO.File]::ReadAllText((Join-Path $repo $rel)) }
function Write-Text($rel, $text) {
    [System.IO.File]::WriteAllText((Join-Path $repo $rel), $text, $utf8NoBom)
    Write-Host "  updated $rel" -ForegroundColor Green
}
# Replace the first regex match only; fail loudly if the anchor moved.
function Replace-One($text, $pattern, $replacement, $where) {
    $rx = [regex]$pattern
    if (-not $rx.IsMatch($text)) { throw "No '$where' match — check the file format." }
    return $rx.Replace($text, $replacement, 1)
}

# ── app/pubspec.yaml — bump the +build number too (Android needs it monotonic) ──
$pub = Read-Text 'app/pubspec.yaml'
$build = if ($pub -match '(?m)^version:\s*\d+\.\d+\.\d+\+(\d+)') { [int]$Matches[1] + 1 } else { 1 }
$pub = Replace-One $pub '(?m)^version:\s*\S+' "version: $Version+$build" 'pubspec version'
Write-Text 'app/pubspec.yaml' $pub

# ── core/Cargo.toml — only the [package] version (deps use inline tables) ──
$cargo = Read-Text 'core/Cargo.toml'
$cargo = Replace-One $cargo '(?m)^version\s*=\s*"[^"]*"' "version = `"$Version`"" 'Cargo package version'
Write-Text 'core/Cargo.toml' $cargo

# ── extension manifests (source; rebuild dist/ after) ──
foreach ($mf in 'extension/chromium/manifest.json', 'extension/firefox/manifest.json') {
    $m = Read-Text $mf
    $m = Replace-One $m '"version"\s*:\s*"[^"]*"' "`"version`": `"$Version`"" 'manifest version'
    Write-Text $mf $m
}

# ── CHANGELOG.md — date the Unreleased section and open a fresh one ──
$cl = Read-Text 'CHANGELOG.md'
$cl = Replace-One $cl '##\s*\[Unreleased\]' "## [Unreleased]`n`n## [$Version] - $today" 'Unreleased heading'
$cl = Replace-One $cl '(?m)^\[Unreleased\]:.*$' @"
[Unreleased]: https://github.com/purukitto/Shinsoku/compare/$tag...HEAD
[$Version]: https://github.com/purukitto/Shinsoku/releases/tag/$tag
"@ 'Unreleased link reference'
Write-Text 'CHANGELOG.md' $cl

Write-Host ''
Write-Host "Bumped to $Version." -ForegroundColor Cyan
Write-Host 'Next: rebuild the extension dist so its manifests match -> ./extension/build.ps1'

if ($Commit) {
    git -C $repo add -A
    git -C $repo commit -m "Release $tag"
    git -C $repo tag -a $tag -m $tag
    Write-Host "Committed and tagged $tag. Push with:  git push && git push origin $tag" -ForegroundColor Cyan
}
else {
    Write-Host 'Then review and commit:' -ForegroundColor DarkGray
    Write-Host "  git add -A; git commit -m `"Release $tag`"; git tag -a $tag -m `"$tag`""
    Write-Host "  git push; git push origin $tag"
}
