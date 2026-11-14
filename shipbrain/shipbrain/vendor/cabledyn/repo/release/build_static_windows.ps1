# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
# Build the two redistributable-free Windows release executables:
# CableDyn_driver.exe and a CableDyn-enabled openfast.exe.

[CmdletBinding()]
param(
    [string]$CableDynRoot = '',
    [string]$OpenFASTRoot = '',
    [string]$RTestRoot = '',
    [string]$OutputDir = '',
    [string]$WindowsSdkVersion = '10.0.22621.0',
    [int]$Jobs = 8,
    [version]$MinimumIfxVersion = '2025.3',
    [switch]$AllowUnsupportedCompiler,
    [string]$OneApiSetvars = 'C:\Program Files (x86)\Intel\oneAPI\setvars.bat',
    [string]$MklVars = 'C:\Program Files (x86)\Intel\oneAPI\mkl\latest\env\vars.bat',
    [string]$VcVarsAll = '',
    # Local copy of the pinned reference LAPACK source archive; downloaded when empty.
    [string]$ReferenceLapackArchive = ''
)

$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 does not set $PSScriptRoot while evaluating parameter
# defaults, so the repository-relative defaults are resolved here.
if (-not $CableDynRoot) { $CableDynRoot = Split-Path $PSScriptRoot -Parent }
if (-not $OpenFASTRoot) { $OpenFASTRoot = Join-Path $CableDynRoot '..\openfast' }
$CableDynRoot = (Resolve-Path -LiteralPath $CableDynRoot).Path
$OpenFASTRoot = (Resolve-Path -LiteralPath $OpenFASTRoot).Path
if (-not $OutputDir) { $OutputDir = Join-Path $CableDynRoot 'build-static-release\dist' }
$OutputDir = [IO.Path]::GetFullPath($OutputDir)
$cdBuild = Join-Path $CableDynRoot 'build-static-release\cabledyn'
$ofVsBuild = Join-Path $OpenFASTRoot 'build'

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) {
    throw "Visual Studio locator not found: $vswhere"
}
$vcComponent = 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64'
$vsRoot = (& $vswhere -latest -products * -requires $vcComponent -property installationPath |
    Select-Object -First 1)
if (-not $vsRoot) { throw 'Visual Studio with the x64 C++ toolchain was not found' }
if (-not $VcVarsAll) {
    $VcVarsAll = Join-Path $vsRoot 'VC\Auxiliary\Build\vcvarsall.bat'
}

foreach ($required in @($OneApiSetvars, $MklVars, $VcVarsAll)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "required toolchain script not found: $required" }
}

function Invoke-StaticToolchain([string]$Command) {
    $bat = Join-Path $env:TEMP ("cabledyn-static-{0}.bat" -f [guid]::NewGuid().ToString('N'))
    try {
        @(
            '@echo off'
            "set `"PATH=$(Split-Path $vswhere);%PATH%`""
            "call `"$OneApiSetvars`" --force >nul"
            'if errorlevel 1 exit /b %errorlevel%'
            "call `"$MklVars`" intel64 >nul"
            'if errorlevel 1 exit /b %errorlevel%'
            "call `"$VcVarsAll`" x64 $WindowsSdkVersion >nul"
            'if errorlevel 1 exit /b %errorlevel%'
            $Command
        ) | Set-Content -LiteralPath $bat -Encoding ascii
        & cmd.exe /d /c $bat
        if ($LASTEXITCODE -ne 0) { throw "static toolchain command failed ($LASTEXITCODE): $Command" }
    } finally {
        Remove-Item -LiteralPath $bat -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-NativeCapture([string]$Executable, [string[]]$Arguments) {
    # Merge stdout and stderr into one log. Windows PowerShell 5.1 turns every native
    # stderr line into an ErrorRecord, which is terminating under 'Stop'; relax the
    # preference for the capture and report the native exit code explicitly.
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $text = (& $Executable @Arguments 2>&1 | ForEach-Object { "$_" }) -join "`n"
        return [pscustomobject]@{ Text = $text; ExitCode = $LASTEXITCODE }
    } finally {
        $ErrorActionPreference = $saved
    }
}

# Release binaries must use the same maintained IFX generation as the official
# OpenFAST Windows release. Older IFX builds are useful for local diagnostics but
# are not accepted as portable release artifacts: their binaries are not qualified
# across processor vendors.
$ifxProbe = Join-Path $env:TEMP ("cabledyn-ifx-{0}.txt" -f [guid]::NewGuid().ToString('N'))
try {
    Invoke-StaticToolchain "ifx /QV > `"$ifxProbe`" 2>&1"
    $ifxText = Get-Content -LiteralPath $ifxProbe -Raw
} finally {
    Remove-Item -LiteralPath $ifxProbe -Force -ErrorAction SilentlyContinue
}
if ($ifxText -notmatch 'Version\s+(\d+\.\d+(?:\.\d+)?)') {
    throw "could not determine IFX version from:`n$ifxText"
}
$ifxVersion = [version]$Matches[1]
if ($ifxVersion -lt $MinimumIfxVersion -and -not $AllowUnsupportedCompiler) {
    throw "IFX $ifxVersion is below the portable-release minimum $MinimumIfxVersion. " +
          'Install the pinned release compiler or pass -AllowUnsupportedCompiler for a labelled diagnostic build.'
}
if ($ifxVersion -lt $MinimumIfxVersion) {
    Write-Warning "building a diagnostic artifact with unsupported IFX $ifxVersion (minimum $MinimumIfxVersion)"
} else {
    Write-Host "PASS release compiler gate: IFX $ifxVersion"
}

# A portable release must be reproducible from the pinned, clean public
# OpenFAST base.  Apply the complete host-glue patch series here so the local
# maintainer command and the GitHub release route cannot diverge.  In
# particular, adding only the CableDyn Visual Studio project is insufficient:
# unpatched FAST glue still rejects CompMooring = 5 during input validation.
& (Join-Path $CableDynRoot 'integration\openfast\prepare_openfast_source.ps1') -OpenFASTRoot $OpenFASTRoot

$common = '-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_Fortran_COMPILER=ifx ' +
          '-DCMAKE_C_COMPILER=cl -DCMAKE_LINKER=link -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded'

# CableDyn solves only narrow banded systems. MKL's sequential banded LU spends most
# of its time dispatching per-column level-1/2 kernels on vectors of a few entries,
# so both executables link the netlib reference LAPACK/BLAS, compiled here with the
# release IFX from a pinned, checksummed source archive. /fp:precise keeps IEEE
# semantics inside LAPACK; the upstream CMake applies a strict model only on Unix.
# /arch:CORE-AVX2 is the x86-64-v3 target of the CableDyn core (CABLEDYN_TARGET_AVX2).
$lapackVersion = '3.12.1'
$lapackSha256 = '2ca6407a001a474d4d4d35f3a61550156050c48016d949f0da0529c0aa052422'
$lapackUrl = "https://github.com/Reference-LAPACK/lapack/archive/refs/tags/v$lapackVersion.tar.gz"
$lapackRoot = Join-Path $CableDynRoot 'build-static-release\reference-lapack'
New-Item -ItemType Directory -Path $lapackRoot -Force | Out-Null
if (-not $ReferenceLapackArchive) {
    $ReferenceLapackArchive = Join-Path $lapackRoot "lapack-$lapackVersion.tar.gz"
    if (-not (Test-Path -LiteralPath $ReferenceLapackArchive)) {
        $savedProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        # Windows PowerShell 5.1 may not offer TLS 1.2 by default; GitHub requires it.
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor
            [Net.SecurityProtocolType]::Tls12
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $lapackUrl -OutFile $ReferenceLapackArchive
        } finally {
            $ProgressPreference = $savedProgress
        }
    }
}
$ReferenceLapackArchive = (Resolve-Path -LiteralPath $ReferenceLapackArchive).Path
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
Invoke-StaticToolchain ("cmake -S `"$lapackSource`" -B `"$lapackBuild`" $common " +
    '-DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DBUILD_SINGLE=OFF -DBUILD_DOUBLE=ON ' +
    '-DBUILD_COMPLEX=OFF -DBUILD_COMPLEX16=OFF -DBUILD_INDEX64_EXT_API=OFF ' +
    '-DUSE_OPTIMIZED_BLAS=OFF -DUSE_OPTIMIZED_LAPACK=OFF ' +
    '"-DCMAKE_Fortran_FLAGS=/nologo /libs:static /fp:precise /arch:CORE-AVX2" ' +
    "`"-DCMAKE_INSTALL_PREFIX=$lapackInstall`"")
Invoke-StaticToolchain "cmake --build `"$lapackBuild`" --target blas lapack -j $Jobs"
Invoke-StaticToolchain "cmake --install `"$lapackBuild`""
$lapackLibraries = @('liblapack.lib', 'libblas.lib') | ForEach-Object {
    $library = Join-Path $lapackInstall "lib\$_"
    if (-not (Test-Path -LiteralPath $library)) { throw "reference LAPACK build did not produce $library" }
    $library
}
Write-Host "PASS reference LAPACK $lapackVersion built with IFX: $($lapackLibraries -join ', ')"

$cdLapack = ($lapackLibraries | ForEach-Object { $_ -replace '\\', '/' }) -join ';'
Invoke-StaticToolchain ("cmake -S `"$CableDynRoot`" -B `"$cdBuild`" $common -DCABLEDYN_STATIC_WINDOWS_RELEASE=ON " +
    "`"-DCABLEDYN_STATIC_LAPACK_LIBRARIES=$cdLapack`"")
# Recreate the production artifact even if a prior development build left a
# stale driver executable in this reusable build directory.
Remove-Item -LiteralPath (Join-Path $cdBuild 'CableDyn_driver.exe') -Force -ErrorAction SilentlyContinue
Invoke-StaticToolchain "cmake --build `"$cdBuild`" --target cabledyn_core cabledyn -j $Jobs"

# Match the official OpenFAST Windows release route: integrate CableDyn into the
# maintained Intel Fortran solution and build its non-OpenMP Release|x64 target.
# This preserves the solution's compiler, MKL, stack-reserve, whole-program
# optimisation, and static runtime settings instead of approximating them with a
# separate CMake OpenFAST build. The reference LAPACK is listed explicitly, so
# CableDyn's banded solves resolve to it rather than to the project's MKL.
& (Join-Path $CableDynRoot 'integration\openfast\integrate_openfast_vs_solution.ps1') `
    -OpenFASTRoot $OpenFASTRoot -CableDynRoot $CableDynRoot -CableDynBuildDir $cdBuild `
    -LinkLibraries $lapackLibraries

# The identity openfast.exe must report, derived here independently of the integration script:
# the describe of the pinned OpenFAST commit (never '-dirty') and the CableDyn project version.
$ofDescribe = "$(& git -C $OpenFASTRoot describe --tags --abbrev=8)".Trim()
if ($LASTEXITCODE -ne 0 -or $ofDescribe -notmatch '^v\d+\.\d+\.\d+') {
    throw "the OpenFAST checkout $OpenFASTRoot is not described by a release tag ('$ofDescribe')"
}
if ((Get-Content -LiteralPath (Join-Path $CableDynRoot 'CMakeLists.txt') -Raw) -notmatch
        'project\(CableDynCore VERSION (\d+\.\d+\.\d+)') {
    throw 'CableDyn project version not found in CMakeLists.txt'
}
$expectedOpenFASTVersion = "$ofDescribe-CableDyn-$($Matches[1])"

$devenv = Join-Path $vsRoot 'Common7\IDE\devenv.com'
if (-not (Test-Path -LiteralPath $devenv)) { throw "Visual Studio command-line builder not found: $devenv" }
$openFastBuild = "`"$devenv`" `"$OpenFASTRoot\vs-build\OpenFAST.sln`" /Build `"Release|x64`" " +
                 "/Project `"OpenFAST`" /ProjectConfig `"Release|x64`""
try {
    Invoke-StaticToolchain $openFastBuild
} catch {
    # IFX occasionally reports an internal compiler error while Visual Studio
    # parallel-compiles the large upstream NWTC library. A resumed solution
    # build recompiles the missing object; a deterministic source/link error
    # fails again and still blocks the release.
    Write-Warning "OpenFAST solution build failed once; retrying the resumable Release|x64 build"
    Invoke-StaticToolchain $openFastBuild
}

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$driver = Join-Path $OutputDir 'CableDyn_driver.exe'
$openfast = Join-Path $OutputDir 'openfast.exe'
Copy-Item -LiteralPath (Join-Path $cdBuild 'CableDyn_driver.exe') -Destination $driver -Force
$vsOpenFAST = Join-Path $ofVsBuild 'bin\OpenFAST_Release.exe'
if (-not (Test-Path -LiteralPath $vsOpenFAST)) { throw "Visual Studio OpenFAST output not found: $vsOpenFAST" }
Copy-Item -LiteralPath $vsOpenFAST -Destination $openfast -Force

& (Join-Path $PSScriptRoot 'check_static_windows_binary.ps1') -Path $driver `
    -MinimumStackReserveBytes 268435456 -RequireUtf8CodePage
& (Join-Path $PSScriptRoot 'check_static_windows_binary.ps1') -Path $openfast -RequireUtf8CodePage

# Exercise the packaged driver with compiler/runtime directories removed from PATH.
$savedPath = $env:PATH
$env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
try {
    $versionRun = Invoke-NativeCapture $driver @('--version')
    Write-Host $versionRun.Text
    if ($versionRun.ExitCode -ne 0) { throw 'CableDyn_driver.exe --version failed in isolated PATH' }
    # the release targets x86-64-v3 and carries the start-up processor check
    if ($versionRun.Text -notmatch 'Build\s+x86-64-v3') {
        throw "CableDyn_driver.exe is not the x86-64-v3 build with the processor check`n$($versionRun.Text)"
    }
    # Identity gate: openfast.exe names its OpenFAST base and the CableDyn version.
    $ofVersionRun = Invoke-NativeCapture $openfast @('-v')
    Write-Host $ofVersionRun.Text
    if ($ofVersionRun.ExitCode -ne 0 -or $ofVersionRun.Text -match 'dirty' -or
        $ofVersionRun.Text -notmatch "(?m)^\s*OpenFAST-$([regex]::Escape($expectedOpenFASTVersion))\s*$") {
        throw "openfast.exe -v does not report OpenFAST-$expectedOpenFASTVersion`n$($ofVersionRun.Text)"
    }
    Write-Host "PASS openfast.exe identity: OpenFAST-$expectedOpenFASTVersion"
    # On a processor without x86-64-v3 both executables stop at start with the message
    # (simulated here): exit 3 before any CableDyn or OpenFAST code prints.
    $env:CABLEDYN_CPU_GUARD_SIMULATE = 'SIMULATED-FEATURE'
    try {
        foreach ($stopCase in @(@($driver, '--version'), @($openfast, '-h'))) {
            $stopRun = Invoke-NativeCapture $stopCase[0] @($stopCase[1])
            if ($stopRun.ExitCode -ne 3 -or $stopRun.Text -notmatch 'This computer lacks: SIMULATED-FEATURE' -or
                $stopRun.Text -match 'CableDyn  v|OpenFAST') {
                throw "$($stopCase[0]) did not stop at start on a processor without x86-64-v3 " +
                      "(exit $($stopRun.ExitCode))`n$($stopRun.Text)"
            }
        }
    } finally {
        Remove-Item Env:CABLEDYN_CPU_GUARD_SIMULATE -ErrorAction SilentlyContinue
    }
    $driverRoot = Join-Path $cdBuild 'driver_static_smoke'
    & $driver (Join-Path $CableDynRoot 'examples\chain_catenary_shallow_30m.dat') $driverRoot
    if ($LASTEXITCODE -ne 0) { throw 'CableDyn_driver.exe static smoke case failed' }

    # Exit-contract gate: a run states the contract at start, and a refused input exits 1
    # with the closing line last on stderr (doc/standalone_driver.rst, "Exit status").
    $contractRun = Invoke-NativeCapture $driver @(
        (Join-Path $CableDynRoot 'examples\chain_catenary_shallow_30m.dat'), $driverRoot)
    if ($contractRun.ExitCode -ne 0 -or $contractRun.Text -notmatch '(?m)^\s*Exit status: .*ended with exit code <n>') {
        throw "CableDyn_driver.exe does not state its exit contract at start`n$($contractRun.Text)"
    }
    $refusal = Invoke-NativeCapture $driver @((Join-Path $cdBuild 'no_such_deck.dat'), (Join-Path $cdBuild 'no_such'))
    $refusalLast = @($refusal.Text -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -Last 1
    if ($refusal.ExitCode -ne 1 -or $refusalLast -notmatch '^CableDyn_driver: ended with exit code 1\s*$') {
        throw "CableDyn_driver.exe refused input did not end with the closing line (exit $($refusal.ExitCode))`n$($refusal.Text)"
    }
    Write-Host 'PASS exit contract: start-up statement and closing line on a refused input'

    # Non-ANSI folder gate: a working folder whose name mixes Latin-1, Hangul, and accented
    # characters is outside every single ANSI code page, so only the embedded UTF-8
    # active-code-page manifest lets the Fortran runtime open files there. Run once from
    # inside the folder with relative names and once from outside with absolute names.
    $unicodeName = "{0} {1}{2} {3}" -f [char]0x00FC, [char]0xD55C, [char]0xAE00, [char]0x00E9
    $unicodeDir = Join-Path $cdBuild ("unicode-smoke\" + $unicodeName)
    if (Test-Path -LiteralPath $unicodeDir) { Remove-Item -LiteralPath $unicodeDir -Recurse -Force }
    New-Item -ItemType Directory -Path $unicodeDir -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $CableDynRoot 'examples\chain_catenary_shallow_30m.dat') `
        -Destination (Join-Path $unicodeDir 'deck.dat') -Force
    Push-Location -LiteralPath $unicodeDir
    try {
        $unicodeRun = Invoke-NativeCapture $driver @('deck.dat', 'relative')
    } finally {
        Pop-Location
    }
    if ($unicodeRun.ExitCode -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $unicodeDir 'relative.out'))) {
        throw "CableDyn_driver.exe cannot run a deck in the non-ANSI folder $unicodeDir`n$($unicodeRun.Text)"
    }
    $unicodeRun = Invoke-NativeCapture $driver @((Join-Path $unicodeDir 'deck.dat'), (Join-Path $unicodeDir 'absolute'))
    if ($unicodeRun.ExitCode -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $unicodeDir 'absolute.out'))) {
        throw "CableDyn_driver.exe cannot use absolute non-ANSI paths under $unicodeDir`n$($unicodeRun.Text)"
    }

    # The maintained 952-element Gulf of Maine cable is the release-scale dynamic
    # gate. One held-end step is enough to exercise the large Hermite march, its
    # qualified nonlinear controls, and the PE stack reserve in the packaged exe.
    $gomaineDeck = Join-Path $cdBuild 'gomaine_release_dynamic.dat'
    $gomaineRoot = Join-Path $cdBuild 'gomaine_release_dynamic'
    $gomaineLines = Get-Content -LiteralPath (Join-Path $CableDynRoot 'examples\lozon_gomaine200_power_cable.dat')
    $tmaxRows = 0
    $solverRows = 0
    $tensileAuditRows = 0
    $gomaineLines = foreach ($line in $gomaineLines) {
        if ($line -match '^\s*[0-9.eE+-]+\s+TMax\b') {
            $tmaxRows++
            $line -replace '^(\s*)[0-9.eE+-]+(\s+TMax\b)', '${1}0.05${2}'
        } else {
            if ($line -match '^\s*dynamic_solver\s+1\.0e-4\s+1\.0e-14\s+100\s+12\b') { $solverRows++ }
            if ($line -match '^\s*warn\s+tensile_safety\b') { $tensileAuditRows++ }
            $line
        }
    }
    if ($tmaxRows -ne 1 -or $solverRows -ne 1 -or $tensileAuditRows -ne 1) {
        throw "GoMaine release gate requires one TMax, qualified dynamic_solver, and warning tensile audit"
    }
    $gomaineLines | Set-Content -LiteralPath $gomaineDeck -Encoding ascii
    $gomaineRun = Invoke-NativeCapture $driver @($gomaineDeck, $gomaineRoot)
    $gomaineLog = $gomaineRun.Text
    if ($gomaineRun.ExitCode -ne 0) { throw "CableDyn_driver.exe GoMaine dynamic smoke failed`n$gomaineLog" }
    if ($gomaineLog -notmatch 'Dynamic simulation:\s+1 step' -or
        $gomaineLog -notmatch 'converged run written') {
        throw "CableDyn_driver.exe GoMaine smoke did not prove a completed dynamic step`n$gomaineLog"
    }

    # Long-run memory gate: a 10x longer march must not raise the peak private commit
    # by more than a small bound. Covers the EI=0 time loop and the Hermite march. The
    # memory is sampled every 100 ms, so each short run must last long enough to reach its
    # steady footprint: a 100 s chain run ends within one sample, before its buffers exist.
    foreach ($leakCase in @(
            @{ Deck = 'dynamic_chain_current.dat'; Short = 1000.0; Long = 10000.0 }
            @{ Deck = 'lozon_gomex80_power_cable.dat'; Short = 3.0; Long = 30.0 })) {
        $peaks = @{}
        foreach ($span in 'Short', 'Long') {
            $leakDeck = Join-Path $cdBuild ("leak_{0}_{1}" -f $span, $leakCase.Deck)
            $leakRows = 0
            $leakSource = Join-Path $CableDynRoot "examples\$($leakCase.Deck)"
            $leakLines = foreach ($line in (Get-Content -LiteralPath $leakSource)) {
                if ($line -match '^\s*[0-9.eE+-]+\s+TMax\b') {
                    $leakRows++
                    $line -replace '^(\s*)[0-9.eE+-]+(\s+TMax\b)', ('${1}' + $leakCase[$span] + '${2}')
                } else { $line }
            }
            if ($leakRows -ne 1) { throw "memory gate deck $($leakCase.Deck) must have one TMax row" }
            $leakLines | Set-Content -LiteralPath $leakDeck -Encoding ascii
            $leakRoot = [IO.Path]::ChangeExtension($leakDeck, $null).TrimEnd('.')
            $proc = Start-Process -FilePath $driver -ArgumentList @("`"$leakDeck`"", "`"$leakRoot`"") `
                -PassThru -NoNewWindow -RedirectStandardOutput "$leakRoot.stdout.txt" `
                -RedirectStandardError "$leakRoot.stderr.txt"
            $null = $proc.Handle
            $peak = 0
            while (-not $proc.HasExited) {
                try { $proc.Refresh(); $peak = [math]::Max($peak, $proc.PrivateMemorySize64) } catch { }
                Start-Sleep -Milliseconds 100
            }
            $proc.WaitForExit()
            if ($proc.ExitCode -ne 0) {
                throw "memory gate run $($leakCase.Deck) ($span) failed`n$(Get-Content -Raw "$leakRoot.stderr.txt")"
            }
            $peaks[$span] = $peak / 1MB
        }
        $growth = $peaks['Long'] - $peaks['Short']
        Write-Host ("memory gate {0}: peak private {1:F1} MiB (short) -> {2:F1} MiB (10x steps)" -f `
                $leakCase.Deck, $peaks['Short'], $peaks['Long'])
        if ($growth -gt 16.0) {
            throw ("CableDyn_driver.exe memory grows with run length on {0}: +{1:F1} MiB" -f `
                    $leakCase.Deck, $growth)
        }
    }

    if ($RTestRoot) {
        $RTestRoot = (Resolve-Path -LiteralPath $RTestRoot).Path
        $sourceCase = Join-Path $RTestRoot 'glue-codes\fast-farm\MD_Shared'
        if (-not (Test-Path -LiteralPath $sourceCase)) { throw "MD_Shared smoke model not found: $sourceCase" }
        $smokeDir = Join-Path (Split-Path $cdBuild -Parent) 'openfast-static-smoke'
        if (Test-Path -LiteralPath $smokeDir) {
            $resolvedSmoke = [IO.Path]::GetFullPath($smokeDir)
            $resolvedBuild = [IO.Path]::GetFullPath((Split-Path $cdBuild -Parent))
            if (-not $resolvedSmoke.StartsWith($resolvedBuild, [StringComparison]::OrdinalIgnoreCase)) {
                throw "refusing to remove smoke directory outside build root: $resolvedSmoke"
            }
            Remove-Item -LiteralPath $resolvedSmoke -Recurse -Force
        }
        Copy-Item -LiteralPath $sourceCase -Destination $smokeDir -Recurse
        # MD_Shared is a two-turbine FAST.Farm case: its turbine-1 files start the platform at
        # the farm pose (20.3 m surge, 180 deg yaw) with HydroDyn PtfmRefY = 180, which
        # stretches the single-turbine decks' line 1 to a meaningless ~321 MN. Apply the pose
        # reset of doc/tutorial_openfast.rst (step 3) with the same patterns, and require that
        # it hits exactly the six ElastoDyn platform DOFs and the one HydroDyn reference yaw.
        $poseEdits = @(
            @{ File = 'IEA-15-240-RWT-UMaineSemi_ElastoDynT1.dat'; Count = 6
               Pattern = '^\s*\S+(\s+Ptfm(Surge|Sway|Heave|Roll|Pitch|Yaw)\s)'; Value = '          0$1' },
            @{ File = 'IEA-15-240-RWT-UMaineSemi_HydroDynT1.dat'; Count = 1
               Pattern = '^\s*\S+(\s+PtfmRefY\s)'; Value = '             0$1' }
        )
        foreach ($edit in $poseEdits) {
            $posePath = Join-Path $smokeDir $edit.File
            $poseLines = Get-Content -LiteralPath $posePath
            $poseHits = @($poseLines | Where-Object { $_ -match $edit.Pattern }).Count
            if ($poseHits -ne $edit.Count) {
                throw "pose reset expected $($edit.Count) row(s) in $($edit.File); found $poseHits"
            }
            ($poseLines -replace $edit.Pattern, $edit.Value) | Set-Content -LiteralPath $posePath -Encoding ascii
        }
        $fst = Join-Path $smokeDir 'CableDyn_static_release_smoke.fst'
        Copy-Item -LiteralPath (Join-Path $CableDynRoot 'examples\openfast\IEA-15-UMaine_CompMooring5_CableDyn.fst') `
            -Destination $fst
        Copy-Item -LiteralPath (Join-Path $CableDynRoot 'examples\openfast\CableDyn_UMaine.dat') -Destination $smokeDir
        $fstLines = Get-Content -LiteralPath $fst
        $replaced = 0
        $fstLines = foreach ($line in $fstLines) {
            if ($line -match '^\s*[0-9.eE+-]+\s+TMax\b') {
                $replaced++
                $line -replace '^(\s*)[0-9.eE+-]+(\s+TMax\b)', '${1}1.0${2}'
            } else { $line }
        }
        if ($replaced -ne 1) { throw "expected one TMax row in OpenFAST smoke template; found $replaced" }
        # Preserve the shipped template's NumCrctn value. In particular, the normal
        # `ModCoupling = 3`, `NumCrctn = 0` pathway must initialize and run; changing
        # it to one correction here would hide a release-blocking input/output-Jacobian
        # singularity in exactly the user-facing executable configuration.
        $fstLines | Set-Content -LiteralPath $fst -Encoding ascii
        $run = Invoke-NativeCapture $openfast @($fst)
        $runLog = $run.Text
        Write-Host $runLog
        if ($run.ExitCode -ne 0) { throw "openfast.exe smoke case failed`n$runLog" }
        if ($runLog -notmatch 'Running CableDyn \(' -or $runLog -notmatch 'OpenFAST terminated normally') {
            throw "openfast.exe did not prove CableDyn identity and normal termination`n$runLog"
        }
        if ($runLog -notmatch 'CableDyn build: x86-64-v3') {
            throw "openfast.exe does not carry the x86-64-v3 CableDyn core with the processor check`n$runLog"
        }
        if ($runLog -notmatch 'Created CableDyn model:' -or
            $runLog -notmatch 'Line 1 fairlead effective tension:' -or
            $runLog -notmatch ('Requested CableDyn OUTPUTS at t = 0 s \(equilibrium pose, SeaState ' +
                               'kinematics at t = 0\):') -or
            $runLog -notmatch 'FairTen1\s*=') {
            throw "openfast.exe did not print the CableDyn initialization and requested-output reports`n$runLog"
        }
        $resultFile = [IO.Path]::ChangeExtension($fst, '.out')
        if (-not (Test-Path -LiteralPath $resultFile) -or
            -not (Select-String -LiteralPath $resultFile -Pattern 'FairTen1' -Quiet)) {
            throw 'openfast.exe result table did not carry the requested CableDyn channels'
        }
        $cdRoot = [IO.Path]::Combine($smokeDir, [IO.Path]::GetFileNameWithoutExtension($fst) + '.CD')
        $cdDynamic = $cdRoot + '.out'
        $cdStatic = $cdRoot + '.static.out'
        foreach ($owned in @($cdDynamic, $cdStatic)) {
            if (-not (Test-Path -LiteralPath $owned)) {
                throw "openfast.exe did not write CableDyn-owned result file: $owned"
            }
        }
        if (-not (Select-String -LiteralPath $cdStatic -Pattern 'Inclination' -Quiet) -or
            -not (Select-String -LiteralPath $cdStatic -Pattern 'Curvature' -Quiet)) {
            throw 'CableDyn coupled static profile is missing nodal statics columns'
        }
        $times = @(Get-Content -LiteralPath $cdDynamic | Select-Object -Skip 2 | ForEach-Object {
            $token = ($_ -split '\s+' | Where-Object { $_ })[0]
            [double]::Parse($token, [Globalization.CultureInfo]::InvariantCulture)
        })
        $expectedDtM = 0.025
        $expectedRows = [int][math]::Round(1.0/$expectedDtM) + 1
        if ($times.Count -ne $expectedRows) {
            throw "CableDyn committed-step file has $($times.Count) rows; expected $expectedRows at dtM=$expectedDtM s"
        }
        for ($i = 1; $i -lt $times.Count; $i++) {
            if ([math]::Abs(($times[$i] - $times[$i - 1]) - $expectedDtM) -gt 1.0e-9) {
                throw "CableDyn committed-step file is not sampled at dtM = $expectedDtM s"
            }
        }
        # Physical-configuration gate: with the platform at the origin the t = 0 row is the
        # static equilibrium, whose fairlead tensions are the ~2.40 MN chain pretension (the
        # VolturnUS-S deck reference is 2.395 MN per line). A mis-posed platform gives ~321 MN.
        $cdLines = @(Get-Content -LiteralPath $cdDynamic)
        # Row 0 is the channel header, row 1 the units, row 2 the t = 0 values.
        $cdHeader = @($cdLines[0] -split '\s+' | Where-Object { $_ })
        $cdFirst = @($cdLines[2] -split '\s+' | Where-Object { $_ })
        foreach ($chan in @('FairTen1', 'FairTen2', 'FairTen3')) {
            $col = [array]::IndexOf($cdHeader, $chan)
            if ($col -lt 0) { throw "CableDyn committed-step file has no $chan column" }
            $ten = [double]::Parse($cdFirst[$col], [Globalization.CultureInfo]::InvariantCulture)
            if ($ten -lt 2.28e6 -or $ten -gt 2.52e6) {
                throw "CableDyn initial $chan = $ten N is outside the 2.28-2.52 MN pretension band (platform pose?)"
            }
        }
        # Report-consistency gate: the initialization summary and the static profile describe
        # the same converged equilibrium, so each line's printed fairlead tension must equal
        # its End A (node 1) tension in <root>.CD.static.out. The SeaState kinematics act from
        # t = 0, so the t = 0 OUTPUTS (checked above) are labelled separately and may differ.
        $staticRows = @(Get-Content -LiteralPath $cdStatic | Select-Object -Skip 3)
        foreach ($lineId in 1..3) {
            $hit = [regex]::Match($runLog, "Line $lineId fairlead effective tension:\s*([0-9.Ee+-]+) N")
            if (-not $hit.Success) { throw "openfast.exe did not print the line $lineId fairlead tension" }
            $summaryTen = [double]::Parse($hit.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
            $profileTen = $null
            foreach ($row in $staticRows) {
                $cells = @($row -split '\s+' | Where-Object { $_ })
                if ($cells.Count -ge 7 -and $cells[0] -eq "$lineId" -and $cells[1] -eq '1') {
                    $profileTen = [double]::Parse($cells[6], [Globalization.CultureInfo]::InvariantCulture)
                    break
                }
            }
            if ($null -eq $profileTen) { throw "CableDyn static profile has no line $lineId End A row" }
            if ([math]::Abs($summaryTen - $profileTen) -gt 1.0e-5*[math]::Abs($profileTen)) {
                throw "line $lineId summary tension $summaryTen N differs from the static profile's $profileTen N"
            }
        }

        # Non-ANSI folder gate for openfast.exe: the same smoke model, run from a folder
        # whose name no single ANSI code page can spell (see the driver gate above).
        $ofUnicodeDir = Join-Path (Split-Path $cdBuild -Parent) `
            ("openfast-unicode-smoke\{0} {1}{2} {3}" -f [char]0x00FC, [char]0xD55C, [char]0xAE00, [char]0x00E9)
        if (Test-Path -LiteralPath $ofUnicodeDir) { Remove-Item -LiteralPath $ofUnicodeDir -Recurse -Force }
        New-Item -ItemType Directory -Path $ofUnicodeDir -Force | Out-Null
        Get-ChildItem -LiteralPath $smokeDir |
            Where-Object { $_.PSIsContainer -or $_.Extension -notin '.out', '.sum' } |
            Copy-Item -Destination $ofUnicodeDir -Recurse -Force
        Push-Location -LiteralPath $ofUnicodeDir
        try {
            $ofUnicodeRun = Invoke-NativeCapture $openfast @([IO.Path]::GetFileName($fst))
        } finally {
            Pop-Location
        }
        $ofUnicodeOut = Join-Path $ofUnicodeDir ([IO.Path]::GetFileNameWithoutExtension($fst) + '.out')
        if ($ofUnicodeRun.ExitCode -ne 0 -or $ofUnicodeRun.Text -notmatch 'Running CableDyn \(' -or
            $ofUnicodeRun.Text -notmatch 'OpenFAST terminated normally' -or
            -not (Test-Path -LiteralPath $ofUnicodeOut)) {
            throw "openfast.exe cannot run the smoke model in the non-ANSI folder $ofUnicodeDir`n$($ofUnicodeRun.Text)"
        }

        # A CableDyn-enabled executable must remain a correct stock OpenFAST binary
        # when CompMooring=3. This twin uses the same turbine/environment and exact
        # ModCoupling/NumCrctn settings, changing only the selected mooring module and
        # its input deck. It guards global registry/layout changes independently of CD.
        $mdFst = Join-Path $smokeDir 'MoorDyn_static_release_smoke.fst'
        Copy-Item -LiteralPath (Join-Path $CableDynRoot 'examples\openfast\MoorDyn_UMaine.dat') -Destination $smokeDir
        $mdLines = Get-Content -LiteralPath $fst
        $mdComp = 0
        $mdFile = 0
        $mdLines = foreach ($line in $mdLines) {
            if ($line -match '^\s*5\s+CompMooring\b') {
                $mdComp++
                $line -replace '^(\s*)5(\s+CompMooring\b)', '${1}3${2}'
            } elseif ($line -match '^\s*"[^"]+"\s+MooringFile\b') {
                $mdFile++
                $line -replace '^(\s*)"[^"]+"(\s+MooringFile\b)', '${1}"MoorDyn_UMaine.dat"${2}'
            } else { $line }
        }
        if ($mdComp -ne 1 -or $mdFile -ne 1) {
            throw "could not construct CompMooring=3 twin (CompMooring=$mdComp, MooringFile=$mdFile)"
        }
        $mdLines | Set-Content -LiteralPath $mdFst -Encoding ascii
        $mdRun = Invoke-NativeCapture $openfast @($mdFst)
        $mdLog = $mdRun.Text
        if ($mdRun.ExitCode -ne 0) { throw "openfast.exe CompMooring=3 smoke case failed`n$mdLog" }
        if ($mdLog -notmatch 'Running MoorDyn \(' -or
            $mdLog -notmatch 'MoorDyn initialization completed\.' -or
            $mdLog -notmatch 'OpenFAST terminated normally') {
            throw "openfast.exe did not prove stock MoorDyn identity, initialization, and normal termination`n$mdLog"
        }
    }
} finally {
    $env:PATH = $savedPath
}

$sumLines = foreach ($file in @($driver, $openfast)) {
    $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $([IO.Path]::GetFileName($file))"
}
$sumLines | Set-Content -LiteralPath (Join-Path $OutputDir 'SHA256SUMS.txt') -Encoding ascii
Write-Host "PASS: static Windows release binaries are in $OutputDir"
