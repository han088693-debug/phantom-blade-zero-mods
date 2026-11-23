param([string]$GameRoot = 'E:\SteamLibrary\steamapps\common\PBZ')
$ErrorActionPreference = 'Stop'
function Assert-NoReparseTree([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw "Reparse point is not allowed: $Path"
    }
    if ($item.PSIsContainer) {
        foreach ($child in Get-ChildItem -LiteralPath $Path -Force) {
            Assert-NoReparseTree -Path $child.FullName
        }
    }
}
if (Get-Process -Name PBZ -ErrorAction SilentlyContinue) {
    throw 'Close Phantom Blade Zero before installing.'
}
$game = (Resolve-Path -LiteralPath $GameRoot).Path
$mods = (Resolve-Path -LiteralPath (Join-Path $game 'platform\steam\ue4ss\Mods')).Path
if (-not (Test-Path -LiteralPath (Join-Path $game 'platform\steam\PBZ.exe'))) {
    throw 'PBZ.exe was not found in the selected game directory.'
}
if (Test-Path -LiteralPath (Join-Path $mods 'PBZCoop')) {
    throw 'This preview is for single-player testing. Back up and remove PBZCoop before installing.'
}
$source = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'PBZZuoShangBoss')).Path
Assert-NoReparseTree -Path $source
$target = Join-Path $mods 'PBZZuoShangBoss'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fffffff'
$backupRoot = Join-Path $PSScriptRoot 'backups'
if (Test-Path -LiteralPath $backupRoot) { Assert-NoReparseTree -Path $backupRoot }
$backup = Join-Path $backupRoot ('install-' + $stamp)
if (Test-Path -LiteralPath $target) {
    $resolved = (Resolve-Path -LiteralPath $target).Path
    if ($resolved -ne $target -or (Get-Item -LiteralPath $resolved).Attributes.ToString().Contains('ReparsePoint')) {
        throw 'Unexpected existing mod path; installation stopped.'
    }
    Assert-NoReparseTree -Path $resolved
}
New-Item -ItemType Directory -Path $backup | Out-Null
if (Test-Path -LiteralPath $target) {
    $modBackup = Join-Path $backup 'PBZZuoShangBoss'
    Copy-Item -LiteralPath $target -Destination $modBackup -Recurse -Force
    foreach ($file in Get-ChildItem -LiteralPath $target -File -Recurse -Force) {
        $relative = $file.FullName.Substring($target.Length + 1)
        $copied = Join-Path $modBackup $relative
        if ((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ne
            (Get-FileHash -LiteralPath $copied -Algorithm SHA256).Hash) {
            throw "Existing mod backup verification failed; original mod was not changed: $relative"
        }
    }
}
# Saves are copied, never edited. No other mod or loader file is changed.
$saves = Join-Path $game 'ProjectPBZ\Saved\SaveGames'
if (Test-Path -LiteralPath $saves) {
    Assert-NoReparseTree -Path $saves
    Copy-Item -LiteralPath $saves -Destination (Join-Path $backup 'SaveGames') -Recurse -Force
    foreach ($file in Get-ChildItem -LiteralPath $saves -File -Recurse -Force) {
        $relative = $file.FullName.Substring($saves.Length + 1)
        $copied = Join-Path (Join-Path $backup 'SaveGames') $relative
        if ((Get-FileHash -LiteralPath $file.FullName).Hash -ne (Get-FileHash -LiteralPath $copied).Hash) {
            throw "Save backup verification failed: $relative"
        }
    }
}
New-Item -ItemType Directory -Path $target -Force | Out-Null
foreach ($file in Get-ChildItem -LiteralPath $source -File -Recurse -Force) {
    $relative = $file.FullName.Substring($source.Length + 1)
    $destination = Join-Path $target $relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
    if ((Get-FileHash -LiteralPath $file.FullName).Hash -ne (Get-FileHash -LiteralPath $destination).Hash) {
        throw "Installed file verification failed: $relative"
    }
}
Write-Output "Installed PBZZuoShangBoss preview: $target"
Write-Output "Verified save backup: $backup"
Write-Output 'Read README before testing. Full boss progression and rewards are not yet verified.'
