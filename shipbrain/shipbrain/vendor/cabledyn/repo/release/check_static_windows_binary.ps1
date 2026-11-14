# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
# Fail closed unless a Windows executable imports only operating-system DLLs and, when
# requested, embeds the UTF-8 active-code-page manifest.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [UInt64]$MinimumStackReserveBytes = 0,

    # Require the manifest of app/utf8_code_page.manifest (activeCodePage UTF-8).
    [switch]$RequireUtf8CodePage
)

$ErrorActionPreference = 'Stop'
$exe = (Resolve-Path -LiteralPath $Path).Path

$dumpbin = Get-Command dumpbin.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $dumpbin) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) {
        throw 'dumpbin.exe is not on PATH and vswhere.exe was not found'
    }
    $vsRoot = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath
    $candidate = Get-ChildItem -LiteralPath (Join-Path $vsRoot 'VC\Tools\MSVC') -Directory |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName 'bin\Hostx64\x64\dumpbin.exe' } |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1
    if ($null -eq $candidate) { throw 'could not locate dumpbin.exe in Visual Studio' }
    $dumpbinPath = $candidate
} else {
    $dumpbinPath = $dumpbin.Source
}

# dumpbin reports its errors on stdout. Its stderr is not redirected: under Windows
# PowerShell 5.1 a redirected native stderr line becomes a terminating error record.
$text = (& $dumpbinPath /nologo /dependents $exe | Out-String)
if ($LASTEXITCODE -ne 0) { throw "dumpbin failed for $exe`n$text" }
$imports = @([regex]::Matches($text, '(?im)^\s+([A-Za-z0-9_.-]+\.dll)\s*$') |
    ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
if ($imports.Count -eq 0) { throw "$exe has no readable PE import table" }

$forbidden = '^(?:libgfortran|libgcc|libquadmath|libgomp|libwinpthread|openblas|libopenblas|' +
             'mkl_|libif|libiomp|svml|vcruntime|msvcp)'
$bad = foreach ($dll in $imports) {
    if ($dll -match $forbidden) { $dll; continue }
    if ($dll -match '^(?:api-ms-win-|ext-ms-win-)') { continue }
    if (-not (Test-Path -LiteralPath (Join-Path $env:SystemRoot "System32\$dll"))) { $dll }
}
if (@($bad).Count -gt 0) {
    throw "$exe imports non-system runtime DLL(s): $(@($bad) -join ', ')"
}

$stackReserve = 0
if ($MinimumStackReserveBytes -gt 0) {
    $headers = (& $dumpbinPath /nologo /headers $exe | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "dumpbin header inspection failed for $exe`n$headers" }
    $match = [regex]::Match($headers, '(?im)^\s*([0-9a-f]+)\s+size of stack reserve\s*$')
    if (-not $match.Success) { throw "$exe has no readable PE stack-reserve field" }
    $stackReserve = [Convert]::ToUInt64($match.Groups[1].Value, 16)
    if ($stackReserve -lt $MinimumStackReserveBytes) {
        throw "$exe stack reserve is $stackReserve bytes; require at least $MinimumStackReserveBytes"
    }
}

if ($RequireUtf8CodePage) {
    # The embedded manifest is stored as UTF-8 text in the RT_MANIFEST resource.
    $image = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($exe))
    $manifests = @([regex]::Matches($image, '(?s)<assembly\b.{0,4000}?</assembly>') | ForEach-Object { $_.Value })
    if ($manifests.Count -eq 0) { throw "$exe has no embedded application manifest" }
    $utf8 = @($manifests | Where-Object { $_ -match '<activeCodePage\b[^>]*>\s*UTF-8\s*</activeCodePage>' })
    if ($utf8.Count -eq 0) { throw "$exe does not declare the UTF-8 active code page in its manifest" }
    if ($utf8[0] -notmatch 'requestedExecutionLevel\s+level="asInvoker"') {
        throw "$exe manifest lost the asInvoker execution level"
    }
}

$hash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host "PASS static dependency audit: $exe"
Write-Host "  imports: $($imports -join ', ')"
if ($MinimumStackReserveBytes -gt 0) { Write-Host "  stack reserve: $stackReserve bytes" }
Write-Host "  sha256: $hash"
