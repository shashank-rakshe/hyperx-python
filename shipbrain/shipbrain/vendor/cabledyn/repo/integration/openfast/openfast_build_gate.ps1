# File: integration/openfast/openfast_build_gate.ps1
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
#
# OPENFAST-TREE BUILD GATE (release checklist, run locally against an OpenFAST checkout).
#
# WHY THIS EXISTS: this repository's CMake/CTest builds and tests the solver core and the
# FMF/aggregate shells (src/CableDyn_OpenFAST*.f90), but NOT the registry-generated
# CompMooring = 5 host module (src/openfast/CableDyn_OF.f90 + CableDyn_Types.f90) -- that
# module compiles only inside an OpenFAST tree against the NWTC framework. A green CTest
# suite therefore does NOT prove the real OpenFAST module compiles, initializes, and steps.
# This gate closes that hole with three fail-closed checks:
#
#   1. BUILD  -- the OpenFAST tree (with CableDyn as its CompMooring = 5 module) compiles
#                to openfast.exe with no errors;
#   2. IDENTITY -- a coupled smoke run actually initializes the CableDyn module (the
#                DispNVD identity banner appears in the OpenFAST log output; a build that
#                silently fell back to another mooring module fails here), and the
#                executable names itself OpenFAST-<OpenFAST base>-CableDyn-<version>;
#   3. RUN    -- the smoke case completes (exit 0) and its .out carries finite data to the
#                final row (no NaN/Infinity).
#
# Usage:
#   powershell -File integration/openfast/openfast_build_gate.ps1 -BuildDir <openfast-build-dir> `
#       -CaseFst <path-to-CompMooring5-case.fst> [-TMax 60] [-RequireNativeOutput] [-Clean]
#
# The case must be a CompMooring = 5 .fst whose supporting files (CableDyn deck, SeaState,
# InflowWind/TurbSim boxes) sit beside it -- for example
# examples/openfast/IEA-15-UMaine_CompMooring5_CableDyn.fst with the turbine files its README
# lists. The script copies the .fst to a gate-suffixed name with TMax overridden, so the
# source case file is never modified.

param(
    [Parameter(Mandatory = $true)]
    [string]$BuildDir,
    [Parameter(Mandatory = $true)]
    [string]$CaseFst,
    [double]$TMax = 60.0,
    [int]$Jobs = 8,
    [switch]$RequireNativeOutput,
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
$failures = @()

function Step([string]$name, [scriptblock]$body) {
    Write-Host "== $name"
    & $body
}

# ---- 1. BUILD ------------------------------------------------------------------------
if (-not (Test-Path $BuildDir)) {
    Write-Host "FAIL: OpenFAST build dir not found: $BuildDir"
    Write-Host '      Configure it first (cmake -S <openfast-checkout> -B <BuildDir> ...).'
    exit 1
}
# normalize to absolute paths up front: the smoke run launches the child with the case
# directory as its working directory, so a relative -CaseFst would otherwise be resolved
# against that directory a second time and the run fails before exercising the binary
$BuildDir = (Resolve-Path $BuildDir).Path
if (Test-Path $CaseFst) { $CaseFst = (Resolve-Path $CaseFst).Path }
if ($Clean) {
    Step 'clean (whole tree)' { cmake --build $BuildDir --target clean | Out-Null }
}
# The CableDyn module library is ALWAYS clean-rebuilt: after CableDyn source changes an
# incremental tree build can relink the regenerated registry types against stale consumer
# objects (the Fortran dependency scan does not always propagate), giving an inconsistent
# binary. Coherence is the point of this gate.
# Build steps RETRY ONCE: a leftover or concurrent ninja can hold .ninja_log ("ninja:
# error: opening build log: Permission denied", exit 1). One retry after the lock clears
# separates that transient from a real compile failure; the recorded failure carries the
# exit code.
function BuildTarget([string]$target, [string[]]$extra) {
    cmake --build $BuildDir --target $target -j $Jobs @extra
    if ($LASTEXITCODE -ne 0) {
        $first = $LASTEXITCODE
        # Wait on THIS build directory's .ninja_log lock specifically (an unrelated
        # ninja elsewhere on the machine must neither stall the gate nor mask a real
        # compile failure), bounded by a deadline so a wedged holder still fails.
        Write-Host ("   retry: $target build returned $first (transient ninja lock?) -- " +
                    "probing $BuildDir\.ninja_log")
        $lock = Join-Path $BuildDir '.ninja_log'
        $deadline = (Get-Date).AddMinutes(10)
        while ((Get-Date) -lt $deadline) {
            try {
                $fs = [System.IO.File]::Open($lock, 'Open', 'ReadWrite', 'None')
                $fs.Close()
                break
            } catch { Start-Sleep -Seconds 10 }
        }
        cmake --build $BuildDir --target $target -j $Jobs @extra
        if ($LASTEXITCODE -ne 0) {
            $script:failures += "BUILD: $target failed (exit $first, retry exit $LASTEXITCODE)"
        }
    }
}
Step "build cabledynlib --clean-first (-j $Jobs)" { BuildTarget 'cabledynlib' @('--clean-first') }
Step "build openfast (-j $Jobs)" { BuildTarget 'openfast' @() }
$exe = Join-Path $BuildDir 'glue-codes\openfast\openfast.exe'
if (-not (Test-Path $exe)) {
    # single-config generators (Ninja) put it here; MSVC multi-config under a config
    # dir; non-Windows builds produce an extensionless `openfast`
    $found = Get-ChildItem -Path $BuildDir -Recurse -File |
        Where-Object { $_.Name -eq 'openfast.exe' -or $_.Name -eq 'openfast' } |
        Select-Object -First 1
    if ($null -eq $found) { $failures += 'BUILD: openfast executable not found in the build tree' }
    else { $exe = $found.FullName }
}

# the CableDyn module must have COMPILED into this tree (not merely be present in source)
$mods = Get-ChildItem -Path $BuildDir -Recurse -Filter 'cabledyn*.mod' -ErrorAction SilentlyContinue
if ($null -eq $mods -or @($mods).Count -eq 0) {
    $failures += 'BUILD: no cabledyn*.mod in the build tree -- the CompMooring=5 module did not compile here'
}

if ($failures.Count -gt 0) {
    Write-Host ''
    $failures | ForEach-Object { Write-Host "FAIL: $_" }
    exit 1
}

# ---- 2 + 3. IDENTITY + RUN -----------------------------------------------------------
if (-not (Test-Path $CaseFst)) {
    Write-Host "FAIL: smoke case not found: $CaseFst"
    exit 1
}
$caseDir = Split-Path $CaseFst -Parent
$gateFst = Join-Path $caseDir 'Main_gate_smoke.fst'
# Override TMax without touching the source case (the DLC cases run hours; the gate runs
# a short window -- long enough to cross several mooring steps at dtM = 0.1 s). OpenFAST
# primary files legally carry either order (`4200.0 TMax` or `TMax 4200.0`); match both
# and FAIL CLOSED unless exactly one line was rewritten -- a silent non-override would
# run the full DLC duration (or trip the module's TMax/dtM boundary guard) instead of
# the requested smoke.
$lines = Get-Content $CaseFst
$nrepl = 0
$nfmt = 0
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*[0-9.eE+-]+\s+TMax\b') {
        $lines[$i] = $lines[$i] -replace '^(\s*)[0-9.eE+-]+(\s+TMax\b)', ('${1}' + $TMax + '${2}')
        $nrepl++
    }
    elseif ($lines[$i] -match '^\s*TMax\s+[0-9.eE+-]+') {
        $lines[$i] = $lines[$i] -replace '^(\s*TMax\s+)[0-9.eE+-]+', ('${1}' + $TMax)
        $nrepl++
    }
    elseif ($lines[$i] -match '^\s*[0-9]+\s+OutFileFmt\b') {
        # force TEXT output: a binary-only case (OutFileFmt = 2, common in stock
        # IEA-15MW decks) writes .outb and no .out, which would false-fail the
        # finite-row check below (both legal keyword orders, mirroring TMax)
        $lines[$i] = $lines[$i] -replace '^(\s*)[0-9]+(\s+OutFileFmt\b)', '${1}1${2}'
        $nfmt++
    }
    elseif ($lines[$i] -match '^\s*OutFileFmt\s+[0-9]+') {
        $lines[$i] = $lines[$i] -replace '^(\s*OutFileFmt\s+)[0-9]+', '${1}1'
        $nfmt++
    }
}
if ($nrepl -ne 1) {
    Write-Host "FAIL: expected exactly one TMax line in the case file, rewrote $nrepl"
    exit 1
}
if ($nfmt -gt 1) {
    Write-Host "FAIL: expected at most one OutFileFmt line in the case file, rewrote $nfmt"
    exit 1
}
$lines | Set-Content -Encoding ascii $gateFst
# stale-output guard: a previous run's .out/logs must never satisfy this run's checks
$outFile = [System.IO.Path]::ChangeExtension($gateFst, '.out')
$nativeOutFile = Join-Path $caseDir 'Main_gate_smoke.CD.out'
$stdoutLog = Join-Path $caseDir 'gate_smoke_stdout.log'
$stderrLog = Join-Path $caseDir 'gate_smoke_stderr.log'
foreach ($f in @($outFile, $nativeOutFile, $stdoutLog, $stderrLog)) {
    if (Test-Path $f) { Remove-Item $f -Force }
}

Step ("run smoke (TMax = {0} s)" -f $TMax) {
    # PowerShell 5.1 gotcha: `2>&1` on a native exe wraps every stderr line in an
    # ErrorRecord and (under -ErrorAction Stop) kills the script on the first banner
    # line. Redirect both streams to files instead and read them back.
    $proc = Start-Process -FilePath $exe -ArgumentList ('"' + $gateFst + '"') `
        -WorkingDirectory $caseDir -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog
    $runExit = $proc.ExitCode
    $logText = ''
    foreach ($f in @($stdoutLog, $stderrLog)) {
        if (Test-Path $f) { $logText += (Get-Content $f -Raw) + "`n" }
    }
    if ($runExit -ne 0) { $script:failures += "RUN: openfast exited $runExit" }
    # match the module's OWN DispNVD banner line, not any 'CableDyn' substring -- an
    # echoed path or file name must never satisfy the identity check
    if ($logText -notmatch 'Running CableDyn \(') {
        $script:failures += 'IDENTITY: the CableDyn module banner never appeared -- CompMooring=5 did not initialize'
    }
    # the executable names its OpenFAST base and the CableDyn version (patch 0021), never a
    # '-dirty' describe of the patched tree
    $cdCMake = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\CMakeLists.txt') -Raw
    $cdVersion = [regex]::Match($cdCMake, 'project\(CableDynCore VERSION (\d+\.\d+\.\d+)').Groups[1].Value
    $idPattern = '(?m)^\s*OpenFAST-v\d+\.\d+\.\d+(-\d+-g[0-9a-f]+)?-CableDyn-' + [regex]::Escape($cdVersion) + '\s*$'
    if ($logText -notmatch $idPattern -or $logText -match 'OpenFAST-\S*dirty') {
        $script:failures += "IDENTITY: the OpenFAST banner does not read OpenFAST-<base>-CableDyn-$cdVersion"
    }
}

if (-not (Test-Path $outFile)) {
    $failures += 'RUN: no .out written'
} else {
    # Parse the final data row's fields NUMERICALLY: a diverging run can overflow a
    # formatted field into asterisks or compiler-specific spellings (Inf, -Inf,
    # NaN(...)), which a NaN/Infinity string grep would accept. Every
    # whitespace-separated token must parse as a finite double.
    $tail = Get-Content $outFile -Tail 1
    if ([string]::IsNullOrWhiteSpace($tail)) {
        $failures += 'RUN: final output row missing'
    } else {
        $inv = [System.Globalization.CultureInfo]::InvariantCulture
        foreach ($tok in ($tail -split '\s+' | Where-Object { $_ -ne '' })) {
            $val = 0.0
            $okTok = [double]::TryParse($tok, [System.Globalization.NumberStyles]::Float, $inv, [ref]$val)
            if (-not $okTok -or [double]::IsNaN($val) -or [double]::IsInfinity($val)) {
                $failures += "RUN: final output row carries a non-finite/nonnumeric field: '$tok'"
                break
            }
        }
    }
}

if ($RequireNativeOutput) {
    if (-not (Test-Path $nativeOutFile)) {
        $failures += ('NATIVE OUTPUT: no Main_gate_smoke.CD.out written; select at least one channel ' +
                      'in the CableDyn deck OUTPUTS section')
    } else {
        $nativeLines = @(Get-Content $nativeOutFile)
        $headerCount = @($nativeLines | Where-Object { $_ -match '^Time(?:\s|$)' }).Count
        if ($headerCount -ne 1) {
            $failures += "NATIVE OUTPUT: expected one Time header, found $headerCount"
        }
        if ($nativeLines.Count -lt 4) {
            $failures += 'NATIVE OUTPUT: no complete time history was written'
        } else {
            $inv = [System.Globalization.CultureInfo]::InvariantCulture
            $nativeTimes = New-Object System.Collections.Generic.List[double]
            $nativeWidth = -1
            for ($i = 2; $i -lt $nativeLines.Count; $i++) {
                $tokens = @($nativeLines[$i] -split '\s+' | Where-Object { $_ -ne '' })
                if ($nativeWidth -lt 0) { $nativeWidth = $tokens.Count }
                if ($tokens.Count -ne $nativeWidth) {
                    $failures += "NATIVE OUTPUT: row $($i + 1) has $($tokens.Count) fields; expected $nativeWidth"
                    break
                }
                $rowFinite = $true
                for ($j = 0; $j -lt $tokens.Count; $j++) {
                    $value = 0.0
                    $parsed = [double]::TryParse(
                        $tokens[$j],
                        [System.Globalization.NumberStyles]::Float,
                        $inv,
                        [ref]$value
                    )
                    if (-not $parsed -or [double]::IsNaN($value) -or [double]::IsInfinity($value)) {
                        $failures += "NATIVE OUTPUT: row $($i + 1) field $($j + 1) is not finite"
                        $rowFinite = $false
                        break
                    }
                    if ($j -eq 0) { $nativeTimes.Add($value) }
                }
                if (-not $rowFinite) { break }
            }
            if ($nativeTimes.Count -gt 1) {
                $nativeDt = $nativeTimes[1] - $nativeTimes[0]
                $tol = 1.0e-7 * [Math]::Max(1.0, [Math]::Abs($TMax))
                if ([Math]::Abs($nativeTimes[0]) -gt $tol) {
                    $failures += "NATIVE OUTPUT: first timestamp is $($nativeTimes[0]), not zero"
                }
                if ([Math]::Abs($nativeTimes[$nativeTimes.Count - 1] - $TMax) -gt $tol) {
                    $lastTime = $nativeTimes[$nativeTimes.Count - 1]
                    $failures += "NATIVE OUTPUT: final timestamp is $lastTime, not TMax=$TMax"
                }
                for ($i = 1; $i -lt $nativeTimes.Count; $i++) {
                    $step = $nativeTimes[$i] - $nativeTimes[$i - 1]
                    if ($step -le 0.0 -or [Math]::Abs($step - $nativeDt) -gt $tol) {
                        $failures += "NATIVE OUTPUT: timestamps are duplicated, reversed or gapped at row $($i + 3)"
                        break
                    }
                }
            }
        }
    }
}

Write-Host ''
if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host "FAIL: $_" }
    exit 1
}
Write-Host 'PASS: OpenFAST-tree build gate (module compiled, identified itself, and ran finite)'
if ($RequireNativeOutput) {
    Write-Host 'PASS: CableDyn native output is finite, single-headered, monotone, unique and complete'
}
exit 0
