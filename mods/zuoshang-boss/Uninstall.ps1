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
    throw 'Close Phantom Blade Zero before uninstalling.'
}
$game = (Resolve-Path -LiteralPath $GameRoot).Path
$mods = (Resolve-Path -LiteralPath (Join-Path $game 'platform\steam\ue4ss\Mods')).Path
$target = Join-Path $mods 'PBZZuoShangBoss'
if (-not (Test-Path -LiteralPath $target)) {
    Write-Output 'PBZZuoShangBoss is not installed.'
    exit
}
$resolved = (Resolve-Path -LiteralPath $target).Path
if ($resolved -ne $target -or (Get-Item -LiteralPath $resolved).Attributes.ToString().Contains('ReparsePoint')) {
    throw 'Unexpected mod path; uninstall stopped.'
}
Assert-NoReparseTree -Path $resolved
$backupRoot = Join-Path $PSScriptRoot 'backups'
if (Test-Path -LiteralPath $backupRoot) { Assert-NoReparseTree -Path $backupRoot }
$backup = Join-Path $backupRoot ('uninstall-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fffffff'))
New-Item -ItemType Directory -Path $backup | Out-Null
Copy-Item -LiteralPath $resolved -Destination (Join-Path $backup 'PBZZuoShangBoss') -Recurse -Force
foreach ($file in Get-ChildItem -LiteralPath $resolved -File -Recurse -Force) {
    $relative = $file.FullName.Substring($resolved.Length + 1)
    $copy = Join-Path (Join-Path $backup 'PBZZuoShangBoss') $relative
    if ((Get-FileHash -LiteralPath $file.FullName).Hash -ne (Get-FileHash -LiteralPath $copy).Hash) {
        throw 'Mod backup verification failed; original mod was not removed.'
    }
}
# Exact resolved target checked above; only this mod directory is removed.
Remove-Item -LiteralPath $resolved -Recurse -Force
Write-Output "Removed PBZZuoShangBoss. Backup: $backup"
Write-Output 'Saves, UE4SS, Item Beacon, and other mods were not changed.'
