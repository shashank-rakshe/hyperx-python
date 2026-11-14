# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
# Apply the public, reviewable CableDyn host-integration patch series to its exact OpenFAST base.
# On a checkout where the whole series is already applied (a rerun, for example of
# release/build_static_windows.ps1) it reports that and changes nothing.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OpenFASTRoot,
    [string]$ExpectedRevision = '2895884d2be01862173c88d70f86b358d2f1a50a'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$OpenFASTRoot = (Resolve-Path -LiteralPath $OpenFASTRoot).Path
$patchRoot = Join-Path $repoRoot 'integration\openfast\patches'

if (-not (Test-Path -LiteralPath (Join-Path $OpenFASTRoot '.git'))) {
    throw "OpenFASTRoot is not a git checkout: $OpenFASTRoot"
}

$revisionOut = & git -C $OpenFASTRoot rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $null -eq $revisionOut) { throw "could not read the revision of $OpenFASTRoot" }
$revision = "$revisionOut".Trim()
if ($revision -ne $ExpectedRevision) {
    throw "OpenFAST checkout must be at $ExpectedRevision; found $revision"
}

$patches = @(Get-ChildItem -LiteralPath $patchRoot -Filter '*.patch' | Sort-Object Name)
if ($patches.Count -eq 0) { throw "no OpenFAST integration patches found in $patchRoot" }
$patchPaths = @($patches | ForEach-Object { $_.FullName })

$dirty = (& git -C $OpenFASTRoot status --porcelain=v1)
if ($LASTEXITCODE -ne 0) { throw 'could not inspect the OpenFAST worktree' }
if ($dirty) {
    # A previously integrated tree: the whole series reverses cleanly. Anything else is a
    # locally modified checkout the series must not be layered onto.
    & git -C $OpenFASTRoot apply -R --check --whitespace=nowarn @patchPaths
    if ($LASTEXITCODE -eq 0) {
        Write-Host "PASS: the $($patches.Count) CableDyn integration patches are already applied to OpenFAST $revision"
        return
    }
    throw 'OpenFAST worktree must be clean (or carry exactly this patch series) before applying it'
}

# Registry-generated OpenFAST sources contain historical trailing whitespace.
# Preflight and apply the complete series as one transaction so a bad later patch
# cannot leave a partially integrated worktree behind.
& git -C $OpenFASTRoot apply --check --whitespace=nowarn @patchPaths
if ($LASTEXITCODE -ne 0) { throw 'OpenFAST integration patch series does not apply cleanly' }
& git -C $OpenFASTRoot apply --whitespace=nowarn @patchPaths
if ($LASTEXITCODE -ne 0) { throw 'failed to apply the OpenFAST integration patch series' }

Write-Host "PASS: applied $($patches.Count) CableDyn integration patches to OpenFAST $revision"
