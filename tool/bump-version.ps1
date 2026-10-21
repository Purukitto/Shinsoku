# Bump the version in every manifest and roll the changelog in one step, so the
# app, the Rust core and both extension manifests never drift apart.
#
#   ./tool/bump-version.ps1 0.2.0
#   ./tool/bump-version.ps1 0.2.0 -Commit   # also: commit + annotated tag v0.2.0
#
# It updates:
#   app/pubspec.yaml                          version: X.Y.Z+<build+1>
#   core/Cargo.toml, core/Cargo.lock          shinsoku_core version = "X.Y.Z"
#   extension/chromium|firefox/manifest.json  "version": "X.Y.Z"
#   CHANGELOG.md                              [Unreleased] -> [X.Y.Z] - <today>, compare links
#
# Everything is validated before anything is written, then tool/check-version.ps1
# runs against the new tag: if this succeeds, the release workflow's check will too.
param(
    [Parameter(Mandatory, Position = 0)][string]$Version,
    [switch]$Commit
)
$ErrorActionPreference = 'Stop'

# Plain X.Y.Z only: browser manifests reject pre-release suffixes.
if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Version must be X.Y.Z (got '$Version')."
}

$repo = Split-Path -Parent $PSScriptRoot
$tag = "v$Version"
$today = (Get-Date).ToString('yyyy-MM-dd')
$repoUrl = 'https://github.com/Purukitto/Shinsoku'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Read-Text($rel) { [System.IO.File]::ReadAllText((Join-Path $repo $rel)) }
# Replace the first match only; fail loudly if the anchor moved.
function Replace-One($text, $pattern, $replacement, $where) {
    $rx = [regex]$pattern
    if (-not $rx.IsMatch($text)) { throw "No '$where' match; check the file format." }
    return $rx.Replace($text, $replacement, 1)
}

# -- Preconditions -----------------------------------------------------------

git -C $repo rev-parse -q --verify "refs/tags/$tag" | Out-Null
if ($LASTEXITCODE -eq 0) { throw "Tag $tag already exists." }

if ($Commit -and (git -C $repo status --porcelain)) {
    throw 'Working tree is not clean. Commit or set aside other changes before -Commit.'
}

$pub = Read-Text 'app/pubspec.yaml'
if ($pub -notmatch '(?m)^version:\s*(\d+\.\d+\.\d+)(?:\+(\d+))?') { throw 'No version in app/pubspec.yaml.' }
$current = $Matches[1]
$build = if ($Matches[2]) { [int]$Matches[2] } else { 0 }
if ([version]$Version -lt [version]$current) {
    throw "$Version is lower than the current version $current."
}

$cl = Read-Text 'CHANGELOG.md'
$unreleased = [regex]::Match($cl, '(?ms)^## \[Unreleased\][ \t]*\r?\n(.*?)(?=^## \[|^\[[^\]]+\]:|\z)')
if (-not $unreleased.Success) { throw 'CHANGELOG.md has no "## [Unreleased]" section.' }
if ($unreleased.Groups[1].Value -notmatch '(?m)^\s*- ') {
    throw 'Nothing under [Unreleased] in CHANGELOG.md. Add the entries before cutting a release.'
}
$previous = [regex]::Match($cl, '(?m)^## \[(\d+\.\d+\.\d+)\]')

# -- New contents ------------------------------------------------------------

# The +build number must only ever grow (Android versionCode). Re-running for the
# version already in pubspec (the first release) keeps it.
$nextBuild = if ($Version -eq $current) { [math]::Max($build, 1) } else { $build + 1 }
$files = [ordered]@{}
$files['app/pubspec.yaml'] = Replace-One $pub '(?m)^version:\s*\S+' "version: $Version+$nextBuild" 'pubspec version'

$files['core/Cargo.toml'] = Replace-One (Read-Text 'core/Cargo.toml') '(?m)^version\s*=\s*"[^"]*"' "version = `"$Version`"" 'Cargo package version'
$files['core/Cargo.lock'] = Replace-One (Read-Text 'core/Cargo.lock') '(?m)(^name = "shinsoku_core"\r?\nversion = ")[^"]*(")' "`${1}$Version`${2}" 'Cargo.lock shinsoku_core'

foreach ($mf in 'extension/chromium/manifest.json', 'extension/firefox/manifest.json') {
    $files[$mf] = Replace-One (Read-Text $mf) '"version"\s*:\s*"[^"]*"' "`"version`": `"$Version`"" 'manifest version'
}

$link = if ($previous.Success) {
    "$repoUrl/compare/v$($previous.Groups[1].Value)...$tag"
} else {
    "$repoUrl/releases/tag/$tag"
}
$cl = Replace-One $cl '(?m)^## \[Unreleased\][ \t]*(?=\r?$)' "## [Unreleased]`n`n## [$Version] - $today" 'Unreleased heading'
$cl = Replace-One $cl '(?m)^\[Unreleased\]:[^\r\n]*' "[Unreleased]: $repoUrl/compare/$tag...HEAD`n[$Version]: $link" 'Unreleased link reference'
$files['CHANGELOG.md'] = $cl

# -- Write and verify --------------------------------------------------------

foreach ($rel in $files.Keys) {
    [System.IO.File]::WriteAllText((Join-Path $repo $rel), $files[$rel], $utf8NoBom)
    Write-Host "  updated $rel" -ForegroundColor Green
}

& (Join-Path $PSScriptRoot 'check-version.ps1') -Tag $tag

Write-Host ''
Write-Host "Bumped $current -> $Version." -ForegroundColor Cyan
Write-Host 'To load the extension unpacked at the new version, rebuild it: ./extension/build.ps1' -ForegroundColor DarkGray

if ($Commit) {
    git -C $repo add -- @($files.Keys)
    if ($LASTEXITCODE -ne 0) { throw 'git add failed.' }
    git -C $repo commit -q -m "chore(release): $tag"
    if ($LASTEXITCODE -ne 0) { throw 'git commit failed.' }
    git -C $repo tag -a $tag -m "Shinsoku $tag"
    if ($LASTEXITCODE -ne 0) { throw 'git tag failed.' }
    Write-Host "Committed and tagged $tag. Push to start the release build:" -ForegroundColor Cyan
    Write-Host '  git push --follow-tags'
}
else {
    Write-Host 'Review the diff, then:' -ForegroundColor DarkGray
    Write-Host "  git add -A; git commit -m `"chore(release): $tag`"; git tag -a $tag -m `"Shinsoku $tag`""
    Write-Host '  git push --follow-tags'
}
