# Baut das installierbare Paket dist\de.local.applemusic.streamDeckPlugin
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$src = Join-Path $root 'de.local.applemusic.sdPlugin'
$version = (Get-Content (Join-Path $src 'manifest.json') -Raw | ConvertFrom-Json).Version
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$out = Join-Path $dist 'de.local.applemusic.streamDeckPlugin'
Remove-Item $out -ErrorAction SilentlyContinue
Remove-Item (Join-Path $src 'plugin.log') -ErrorAction SilentlyContinue
# ZipFile statt Compress-Archive: Letzteres schreibt unter PowerShell 5.1 Pfade mit Backslash ins Archiv
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($src, $out, [System.IO.Compression.CompressionLevel]::Optimal, $true)
Write-Host "Fertig: $out (Version $version)"
