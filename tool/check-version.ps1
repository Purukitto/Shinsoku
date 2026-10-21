# Fail unless every manifest carries the same version. With -Tag, also require the
# tag to match it and CHANGELOG.md to have a dated, non-empty section for it. The
# release workflow runs this before building anything.
#
#   ./tool/check-version.ps1
#   ./tool/check-version.ps1 -Tag v0.2.0 -NotesOut notes.md
#
# -NotesOut writes that changelog section's body (the release notes).
# Under GitHub Actions, `version` and `tag` are written to $GITHUB_OUTPUT.
param(
    [string]$Tag,
    [string]$NotesOut
)
$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot

function Read-Text($rel) { [System.IO.File]::ReadAllText((Join-Path $repo $rel)) }
function Find-Version($rel, $pattern) {
    $m = [regex]::Match((Read-Text $rel), $pattern)
    if (-not $m.Success) { throw "No version found in $rel; check the file format." }
    return $m.Groups[1].Value
}

$found = [ordered]@{
    'app/pubspec.yaml'                 = Find-Version 'app/pubspec.yaml' '(?m)^version:\s*([^+\s]+)'
    # First `version =` line is [package]; dependencies use inline tables.
    'core/Cargo.toml'                  = Find-Version 'core/Cargo.toml' '(?m)^version\s*=\s*"([^"]+)"'
    'core/Cargo.lock'                  = Find-Version 'core/Cargo.lock' '(?m)^name = "shinsoku_core"\r?\nversion = "([^"]+)"'
    'extension/chromium/manifest.json' = (Read-Text 'extension/chromium/manifest.json' | ConvertFrom-Json).version
    'extension/firefox/manifest.json'  = (Read-Text 'extension/firefox/manifest.json' | ConvertFrom-Json).version
}

$version = $found['app/pubspec.yaml']
$drift = @($found.Keys | Where-Object { $found[$_] -ne $version })
if ($drift.Count -gt 0) {
    $list = ($found.Keys | ForEach-Object { "  $($found[$_])  $_" }) -join "`n"
    throw "Versions disagree:`n$list`nRun ./tool/bump-version.ps1 rather than editing them by hand."
}

$changelog = Read-Text 'CHANGELOG.md'
if ($changelog -notmatch '(?m)^## \[Unreleased\]') {
    throw 'CHANGELOG.md has no "## [Unreleased]" heading; bump-version.ps1 needs it.'
}

if ($Tag) {
    if ($Tag -ne "v$version") {
        throw "Tag $Tag does not match the manifests ($version)."
    }

    $v = [regex]::Escape($version)
    # Section body runs to the next heading or the link references.
    $section = [regex]::Match($changelog, "(?ms)^## \[$v\] - \d{4}-\d{2}-\d{2}[ \t]*\r?\n(.*?)(?=^## \[|^\[[^\]]+\]:|\z)")
    if (-not $section.Success) {
        throw "CHANGELOG.md has no dated section for $version (expected '## [$version] - YYYY-MM-DD')."
    }
    $notes = $section.Groups[1].Value.Trim()
    if ($notes -notmatch '(?m)^\s*- ') {
        throw "CHANGELOG.md section $version has no entries."
    }
    if ($NotesOut) {
        $out = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($NotesOut)
        [System.IO.File]::WriteAllText($out, "$notes`n", (New-Object System.Text.UTF8Encoding($false)))
    }
}

if ($env:GITHUB_OUTPUT) {
    Add-Content -Path $env:GITHUB_OUTPUT -Value "version=$version"
    Add-Content -Path $env:GITHUB_OUTPUT -Value "tag=v$version"
}

$what = if ($Tag) { ", matching $Tag and its changelog section" } else { '' }
Write-Host "Version $version in all $($found.Count) manifests$what." -ForegroundColor Green
