#Requires -Version 5.1
<#
    tools/fix-encoding.ps1

    Repairs the Windows script encoding problems that break TokenPanel on
    non-UTF-8 (e.g. CP936 / GBK) systems.

    What it does
      1. Adds a UTF-8 BOM to every *.ps1 file that lacks one.
         PowerShell 5.1 decodes a BOM-less script with the active ANSI code
         page, so UTF-8 Chinese text becomes garbage and the parser reports
         dozens of syntax errors (the app dies before it can even write a log).
      2. Reports any *.vbs / *.cmd file that contains non-ASCII bytes and is
         not UTF-16. Those files must stay pure ASCII, or be saved as ANSI/GBK
         (.cmd) / UTF-16 LE with BOM (.vbs).

    Idempotent: running it twice changes nothing the second time.

    Usage
      powershell -NoProfile -ExecutionPolicy Bypass -File tools\fix-encoding.ps1
      powershell ... -File tools\fix-encoding.ps1 -Root D:\Tools\TokenPanel -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$utf8Bom = [byte[]](0xEF, 0xBB, 0xBF)

function Test-HasUtf8Bom {
    param([string]$Path)
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        if ($fs.Length -lt 3) { return $false }
        $head = New-Object byte[] 3
        [void]$fs.Read($head, 0, 3)
        return ($head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF)
    } finally { $fs.Dispose() }
}

function Test-IsUtf16Bom {
    param([string]$Path)
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        if ($fs.Length -lt 2) { return $false }
        $head = New-Object byte[] 2
        [void]$fs.Read($head, 0, 2)
        return (($head[0] -eq 0xFF -and $head[1] -eq 0xFE) -or ($head[0] -eq 0xFE -and $head[1] -eq 0xFF))
    } finally { $fs.Dispose() }
}

function Test-HasNonAscii {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    foreach ($b in $bytes) { if ($b -gt 0x7F) { return $true } }
    return $false
}

Write-Host ("Root: " + $Root)
Write-Host ''

$fixed = 0
$ps1 = Get-ChildItem -Path $Root -Recurse -File -Filter *.ps1 |
    Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }

foreach ($f in $ps1) {
    if (Test-HasUtf8Bom $f.FullName) { continue }
    if ($PSCmdlet.ShouldProcess($f.FullName, 'prepend UTF-8 BOM')) {
        $body = [System.IO.File]::ReadAllBytes($f.FullName)
        [System.IO.File]::WriteAllBytes($f.FullName, [byte[]]($utf8Bom + $body))
        Write-Host ("  BOM added : " + $f.FullName.Substring($Root.Length).TrimStart('\', '/'))
        $fixed++
    }
}

Write-Host ''
Write-Host ("PS1 files scanned : " + $ps1.Count)
Write-Host ("PS1 files fixed   : " + $fixed)

Write-Host ''
Write-Host 'Non-ASCII check (.vbs must be ASCII or UTF-16, .cmd must be ASCII or GBK):'
$warn = 0
foreach ($f in Get-ChildItem -Path $Root -Recurse -File -Include *.vbs, *.cmd |
                Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }) {
    if (Test-IsUtf16Bom $f.FullName) { continue }
    if (Test-HasNonAscii $f.FullName) {
        Write-Warning ("  non-ASCII without UTF-16 BOM: " + $f.FullName)
        $warn++
    }
}
if ($warn -eq 0) { Write-Host '  all clean' }

Write-Host ''
if ($fixed -eq 0 -and $warn -eq 0) {
    Write-Host 'Nothing to do - repo is already encoding-clean.'
} else {
    Write-Host 'Done. Commit the result, then rebuild the release package.'
}
