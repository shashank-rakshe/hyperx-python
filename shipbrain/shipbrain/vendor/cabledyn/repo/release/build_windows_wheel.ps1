# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
# Build the Windows x64 cabledyn wheel with the release toolchain: Intel IFX and the MSVC linker
# with the static runtime, and the pinned netlib reference LAPACK built here with IFX (the same
# pins as build_static_windows.ps1, kept equal by tests/test_packaging_metadata.py). The library
# and the driver in the wheel therefore need no runtime DLLs beyond Windows itself, which the
# script checks with dumpbin before it writes the wheel to OutputDir.
[CmdletBinding()]
param(
    [string]$CableDynRoot = '',
    [string]$OutputDir = '',
    [string]$Python = 'python',
    [string]$WindowsSdkVersion = '10.0.22621.0',
    [int]$Jobs = 8,
    [version]$MinimumIfxVersion = '2025.3',
    [string]$OneApiSetvars = 'C:\Program Files (x86)\Intel\oneAPI\setvars.bat',
    [string]$VcVarsAll = '',
    # Local copy of the pinned reference LAPACK source archive; downloaded when empty.
    [string]$ReferenceLapackArchive = ''
)
$ErrorActionPreference = 'Stop'
if (-not $CableDynRoot) { $CableDynRoot = Split-Path $PSScriptRoot -Parent }
$CableDynRoot = (Resolve-Path -LiteralPath $CableDynRoot).Path
if (-not $OutputDir) { $OutputDir = Join-Path $CableDynRoot 'build-wheel\dist' }
$OutputDir = [IO.Path]::GetFullPath($OutputDir)
$Python = (Get-Command $Python).Source
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) { throw "Visual Studio locator not found: $vswhere" }
$vsRoot = (& $vswhere -latest -products * -requires 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64' `
    -property installationPath | Select-Object -First 1)
if (-not $vsRoot) { throw 'Visual Studio with the x64 C++ toolchain was not found' }
if (-not $VcVarsAll) { $VcVarsAll = Join-Path $vsRoot 'VC\Auxiliary\Build\vcvarsall.bat' }
foreach ($required in @($OneApiSetvars, $VcVarsAll)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "required toolchain script not found: $required" }
}

function Invoke-Toolchain([string]$Command) {
    # Run one command in a cmd.exe with the IFX and MSVC environments loaded.
    $bat = Join-Path $env:TEMP ("cabledyn-wheel-{0}.bat" -f [guid]::NewGuid().ToString('N'))
    try {
        @(
            '@echo off'
            "call `"$OneApiSetvars`" --force >nul"
            'if errorlevel 1 exit /b %errorlevel%'
            "call `"$VcVarsAll`" x64 $WindowsSdkVersion >nul"
            'if errorlevel 1 exit /b %errorlevel%'
            $Command
        ) | Set-Content -LiteralPath $bat -Encoding ascii
        & cmd.exe /d /c $bat
        if ($LASTEXITCODE -ne 0) { throw "toolchain command failed ($LASTEXITCODE): $Command" }
    } finally {
        Remove-Item -LiteralPath $bat -Force -ErrorAction SilentlyContinue
    }
}

# The release compiler gate: the IFX generation of the official executables.
$probe = Join-Path $env:TEMP ("cabledyn-ifx-{0}.txt" -f [guid]::NewGuid().ToString('N'))
try {
    Invoke-Toolchain "ifx /QV > `"$probe`" 2>&1"
    $ifxText = Get-Content -LiteralPath $probe -Raw
} finally {
    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
}
if ($ifxText -notmatch 'Version\s+(\d+\.\d+(?:\.\d+)?)') { throw "could not determine the IFX version from:`n$ifxText" }
if ([version]$Matches[1] -lt $MinimumIfxVersion) {
    throw "IFX $($Matches[1]) is below the release minimum $MinimumIfxVersion"
}
Write-Host "PASS compiler gate: IFX $($Matches[1])"

$common = '-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_Fortran_COMPILER=ifx ' +
          '-DCMAKE_C_COMPILER=cl -DCMAKE_LINKER=link -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded'

# The netlib reference LAPACK/BLAS, static, built with IFX (pins shared with
# build_static_windows.ps1).
$lapackVersion = '3.12.1'
$lapackSha256 = '2ca6407a001a474d4d4d35f3a61550156050c48016d949f0da0529c0aa052422'
$lapackUrl = "https://github.com/Reference-LAPACK/lapack/archive/refs/tags/v$lapackVersion.tar.gz"
$lapackRoot = Join-Path $CableDynRoot 'build-wheel\reference-lapack'
New-Item -ItemType Directory -Path $lapackRoot -Force | Out-Null
if (-not $ReferenceLapackArchive) {
    $ReferenceLapackArchive = Join-Path $lapackRoot "lapack-$lapackVersion.tar.gz"
    if (-not (Test-Path -LiteralPath $ReferenceLapackArchive)) {
        Invoke-WebRequest -UseBasicParsing -Uri $lapackUrl -OutFile $ReferenceLapackArchive
    }
}
$archiveHash = (Get-FileHash -LiteralPath $ReferenceLapackArchive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($archiveHash -ne $lapackSha256) {
    throw "reference LAPACK archive $ReferenceLapackArchive has SHA256 $archiveHash; expected $lapackSha256"
}
$lapackSource = Join-Path $lapackRoot "lapack-$lapackVersion"
$lapackBuild = Join-Path $lapackRoot 'build'
$lapackInstall = Join-Path $lapackRoot 'install'
foreach ($stale in @($lapackSource, $lapackBuild, $lapackInstall)) {
    if (Test-Path -LiteralPath $stale) { Remove-Item -LiteralPath $stale -Recurse -Force }
}
& "$env:SystemRoot\System32\tar.exe" -xzf $ReferenceLapackArchive -C $lapackRoot
if ($LASTEXITCODE -ne 0) { throw "could not extract $ReferenceLapackArchive" }
Invoke-Toolchain ("cmake -S `"$lapackSource`" -B `"$lapackBuild`" $common " +
    '-DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DBUILD_SINGLE=OFF -DBUILD_DOUBLE=ON ' +
    '-DBUILD_COMPLEX=OFF -DBUILD_COMPLEX16=OFF -DBUILD_INDEX64_EXT_API=OFF ' +
    '-DUSE_OPTIMIZED_BLAS=OFF -DUSE_OPTIMIZED_LAPACK=OFF ' +
    '"-DCMAKE_Fortran_FLAGS=/nologo /libs:static /fp:precise /arch:CORE-AVX2" ' +
    "`"-DCMAKE_INSTALL_PREFIX=$lapackInstall`"")
Invoke-Toolchain "cmake --build `"$lapackBuild`" --target blas lapack -j $Jobs"
Invoke-Toolchain "cmake --install `"$lapackBuild`""
$lapackLibraries = @('liblapack.lib', 'libblas.lib') | ForEach-Object {
    $library = Join-Path $lapackInstall "lib\$_"
    if (-not (Test-Path -LiteralPath $library)) { throw "reference LAPACK build did not produce $library" }
    $library -replace '\\', '/'
}
Write-Host "PASS reference LAPACK $lapackVersion built with IFX"

# The wheel: scikit-build-core with the release configuration of CableDyn.
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$settings = @(
    'cmake.args=-GNinja',
    'cmake.define.CMAKE_Fortran_COMPILER=ifx',
    'cmake.define.CMAKE_C_COMPILER=cl',
    'cmake.define.CMAKE_LINKER=link',
    'cmake.define.CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded',
    'cmake.define.CABLEDYN_STATIC_WINDOWS_RELEASE=ON',
    "cmake.define.CABLEDYN_STATIC_LAPACK_LIBRARIES=$($lapackLibraries -join ';')"
) | ForEach-Object { "`"--config-settings=$_`"" }
Invoke-Toolchain ("`"$Python`" -m pip wheel `"$CableDynRoot`" --no-deps -w `"$OutputDir`" " + ($settings -join ' '))
$wheel = Get-ChildItem -LiteralPath $OutputDir -Filter 'cabledyn-*-win_amd64.whl' |
    Sort-Object LastWriteTime | Select-Object -Last 1
if (-not $wheel) { throw "no win_amd64 wheel in $OutputDir" }

# Only Windows system DLLs may be imported by the library and the driver.
$inspect = Join-Path $env:TEMP ("cabledyn-wheel-{0}" -f [guid]::NewGuid().ToString('N'))
try {
    # A wheel is a ZIP archive, but Windows PowerShell 5.1's Expand-Archive refuses any
    # extension other than .zip; the .NET extractor reads it by content.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($wheel.FullName, $inspect)
    # Filter on the extension explicitly: with -LiteralPath, Windows PowerShell 5.1 ignores
    # -Include and would list every file of the package.
    $binaries = @(Get-ChildItem -LiteralPath (Join-Path $inspect 'cabledyn') -Recurse -File |
        Where-Object { $_.Extension -in @('.dll', '.exe') })
    $libraries = @($binaries | Where-Object { $_.Extension -eq '.dll' })
    $drivers = @($binaries | Where-Object { $_.Extension -eq '.exe' -and $_.Directory.Name -eq 'bin' })
    if ($libraries.Count -ne 1 -or $drivers.Count -ne 1 -or $binaries.Count -ne 2) {
        throw "the wheel carries $($binaries.Count) binaries ($($binaries.Name -join ', ')); " +
              'expected the library beside the package and the driver in cabledyn/bin'
    }
    foreach ($binary in $binaries) {
        $listing = Join-Path $env:TEMP ("cabledyn-deps-{0}.txt" -f [guid]::NewGuid().ToString('N'))
        Invoke-Toolchain "dumpbin /nologo /dependents `"$($binary.FullName)`" > `"$listing`""
        $imports = Get-Content -LiteralPath $listing | Where-Object { $_ -match '^\s+\S+\.dll\s*$' } |
            ForEach-Object { $_.Trim() }
        Remove-Item -LiteralPath $listing -Force
        $foreign = $imports | Where-Object {
            $_ -notmatch '^(KERNEL32|ADVAPI32|USER32|SHELL32|OLEAUT32|ole32|WS2_32|ntdll|bcrypt|imagehlp|dbghelp|PSAPI|VERSION)\.dll$' -and
            $_ -notmatch '^api-ms-win-'
        }
        if ($foreign) { throw "$($binary.Name) imports non-system DLLs: $($foreign -join ', ')" }
        Write-Host "PASS $($binary.Name) imports only system DLLs: $($imports -join ', ')"
    }
} finally {
    if (Test-Path -LiteralPath $inspect) { Remove-Item -LiteralPath $inspect -Recurse -Force }
}
Write-Host "PASS $($wheel.Name)"
