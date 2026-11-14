# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
# Add CableDyn to the Intel Fortran Visual Studio solution used for official
# redistributable-free OpenFAST Windows releases.

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$OpenFASTRoot,
    [string]$CableDynRoot = '',
    [Parameter(Mandatory=$true)][string]$CableDynBuildDir,
    # Static libraries the CableDyn core needs at link time, in link order (the
    # static release passes its IFX-built reference LAPACK and BLAS). Listed
    # explicitly, they take precedence over the MKL default libraries of the
    # OpenFAST project.
    [string[]]$LinkLibraries = @()
)

$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 does not set $PSScriptRoot while evaluating parameter defaults.
if (-not $CableDynRoot) { $CableDynRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }
$OpenFASTRoot = (Resolve-Path -LiteralPath $OpenFASTRoot).Path
$CableDynRoot = (Resolve-Path -LiteralPath $CableDynRoot).Path
$CableDynBuildDir = (Resolve-Path -LiteralPath $CableDynBuildDir).Path

$solution = Join-Path $OpenFASTRoot 'vs-build\OpenFAST.sln'
$openfastProject = Join-Path $OpenFASTRoot 'vs-build\glue-codes\OpenFAST.vfproj'
$moduleProject = Join-Path $OpenFASTRoot 'vs-build\modules\CableDyn.vfproj'
$template = Join-Path $CableDynRoot 'integration\openfast\vs-build\CableDyn.vfproj.in'
$moduleDir = Join-Path $CableDynBuildDir 'mod'
$coreLibrary = Join-Path $CableDynBuildDir 'cabledyn_core.lib'
$typesSource = Join-Path $CableDynRoot 'src\openfast\CableDyn_Types.f90'
$moduleSource = Join-Path $CableDynRoot 'src\openfast\CableDyn_OF.f90'
$utf8Manifest = Join-Path $CableDynRoot 'app\utf8_code_page.manifest'

foreach ($required in @($solution, $openfastProject, $template, $moduleDir, $coreLibrary, $typesSource, $moduleSource,
                        $utf8Manifest)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Visual Studio integration input not found: $required" }
}
$LinkLibraries = @($LinkLibraries | ForEach-Object {
    if (-not (Test-Path -LiteralPath $_)) { throw "CableDyn link library not found: $_" }
    (Resolve-Path -LiteralPath $_).Path
})

# Version stamp. The pre-build step of the VersionInfo project, vs-build\CreateGitVersion.bat,
# writes vs-build\gitVersionInfo.h from `git describe --dirty`, so a patched tree would call
# itself '<tag>-dirty'. Name the build after its OpenFAST base and the CableDyn version instead,
# '<OpenFAST describe>-CableDyn-<version>'. `git describe` without --dirty describes the
# checked-out commit, the unpatched base, whether or not the patch series is applied; the
# CableDyn version is the project version of the CableDyn CMakeLists.txt. The pre-build script
# is replaced as a whole and the header written from the same string (at the end of this
# script), so a rerun leaves both unchanged.
$describeOut = & git -C $OpenFASTRoot describe --tags --abbrev=8
if ($LASTEXITCODE -ne 0 -or $null -eq $describeOut) {
    throw "git describe found no tag for the OpenFAST checkout $OpenFASTRoot (fetch its tags)"
}
$baseDescribe = "$describeOut".Trim()
if ($baseDescribe -notmatch '^v\d+\.\d+\.\d+(-\d+-g[0-9a-f]{8,})?$') {
    throw "the OpenFAST base describes as '$baseDescribe', not as a release tag vX.Y.Z or vX.Y.Z-N-gHASH"
}
$cableDynCMake = Get-Content -LiteralPath (Join-Path $CableDynRoot 'CMakeLists.txt') -Raw
if ($cableDynCMake -notmatch 'project\(CableDynCore VERSION (\d+\.\d+\.\d+)') {
    throw 'CableDyn project version not found in CMakeLists.txt'
}
$versionStamp = "$baseDescribe-CableDyn-$($Matches[1])"
$versionDefine = "#define GIT_VERSION_INFO '$versionStamp'"

function Escape-Xml([string]$Value) {
    return [Security.SecurityElement]::Escape($Value)
}

$projectText = Get-Content -LiteralPath $template -Raw
$projectText = $projectText.Replace('@CABLEDYN_MODULE_DIR@', (Escape-Xml $moduleDir))
$projectText = $projectText.Replace('@CABLEDYN_TYPES_SOURCE@', (Escape-Xml $typesSource))
$projectText = $projectText.Replace('@CABLEDYN_MODULE_SOURCE@', (Escape-Xml $moduleSource))
$projectText | Set-Content -LiteralPath $moduleProject -Encoding utf8

$cdGuid = '{C4B9B31E-9B55-4BEA-A6E0-A74E216DCE52}'
$fortranProjectType = '{6989167D-11E4-40FE-8C1A-2192A86A7E90}'
$modulesFolder = '{272B8080-A022-4F4A-BDD6-835871E44C23}'
$dependencyTargets = @(
    '{FE80CE9A-7E16-476D-B63A-F9F870ACB662}', # OpenFAST-Prelib
    '{6906E75C-2A54-431B-A11D-145864FCDD5C}', # OpenFAST-Library
    '{6E5137FC-19EB-4A7F-AAE8-523AAF95A861}'  # OpenFAST executable
)

$sln = Get-Content -LiteralPath $solution -Raw
if ($sln -notmatch [regex]::Escape($cdGuid)) {
    $projectBlock = "Project(`"$fortranProjectType`") = `"CableDyn`", `"modules\CableDyn.vfproj`", `"$cdGuid`"`r`n" +
                    "`tProjectSection(ProjectDependencies) = postProject`r`n" +
                    "`t`t{951A453F-1999-483D-848A-9B63C282F43D} = {951A453F-1999-483D-848A-9B63C282F43D}`r`n" +
                    "`t`t{9CB36EC2-18AF-468E-BE43-FE63E383AA3A} = {9CB36EC2-18AF-468E-BE43-FE63E383AA3A}`r`n" +
                    "`t`t{EAF5E602-E6CD-4194-8CCA-0827AA4CCEC9} = {EAF5E602-E6CD-4194-8CCA-0827AA4CCEC9}`r`n" +
                    "`tEndProjectSection`r`nEndProject`r`n"
    $moorMarker = "Project(`"$fortranProjectType`") = `"MoorDyn`""
    $index = $sln.IndexOf($moorMarker, [StringComparison]::Ordinal)
    if ($index -lt 0) { throw 'MoorDyn project marker not found in OpenFAST.sln' }
    $sln = $sln.Insert($index, $projectBlock)

    foreach ($target in $dependencyTargets) {
        $projectStart = $sln.IndexOf(", `"$target`"", [StringComparison]::OrdinalIgnoreCase)
        if ($projectStart -lt 0) { throw "solution project not found: $target" }
        $sectionEnd = $sln.IndexOf("`tEndProjectSection", $projectStart, [StringComparison]::Ordinal)
        if ($sectionEnd -lt 0) { throw "dependency section not found for $target" }
        $sln = $sln.Insert($sectionEnd, "`t`t$cdGuid = $cdGuid`r`n")
    }

    # Some upstream solution revisions use CRLF and others have been emitted
    # with an additional CR by Visual Studio tooling. Ignore line terminators
    # while cloning the complete project-configuration mapping.
    $moorConfigPattern = '(?m)^(\s*)\{923F8E1F-F5FC-4572-9C32-94C90F04A5A9\}(\.[^\r\n]+)\r*$'
    $moorConfigs = [regex]::Matches($sln, $moorConfigPattern)
    if ($moorConfigs.Count -eq 0) { throw 'MoorDyn configuration mappings not found in OpenFAST.sln' }
    $configLines = ($moorConfigs | ForEach-Object { $_.Groups[1].Value + $cdGuid + $_.Groups[2].Value }) -join "`r`n"
    $configSectionStart = $sln.IndexOf('GlobalSection(ProjectConfigurationPlatforms)', [StringComparison]::Ordinal)
    $configSectionEnd = $sln.IndexOf("`tEndGlobalSection", $configSectionStart, [StringComparison]::Ordinal)
    if ($configSectionEnd -lt 0) { throw 'ProjectConfigurationPlatforms section end not found' }
    $sln = $sln.Insert($configSectionEnd, $configLines + "`r`n")

    $nestedStart = $sln.IndexOf('GlobalSection(NestedProjects)', [StringComparison]::Ordinal)
    $nestedEnd = $sln.IndexOf("`tEndGlobalSection", $nestedStart, [StringComparison]::Ordinal)
    if ($nestedEnd -lt 0) { throw 'NestedProjects section end not found' }
    $sln = $sln.Insert($nestedEnd, "`t`t$cdGuid = $modulesFolder`r`n")
    $sln | Set-Content -LiteralPath $solution -Encoding utf8
}

# Keep the direct dependency list complete when this script is rerun against a
# previously integrated checkout. Intel Fortran needs the producer project in
# the dependency graph to expose module search paths required by SeaState's
# WaveField derived type.
$sln = Get-Content -LiteralPath $solution -Raw
$cdProjectStart = $sln.IndexOf("= `"CableDyn`",", [StringComparison]::Ordinal)
if ($cdProjectStart -lt 0) { throw 'CableDyn project not found after solution integration' }
$cdSectionEnd = $sln.IndexOf("`tEndProjectSection", $cdProjectStart, [StringComparison]::Ordinal)
$ifwGuid = '{9CB36EC2-18AF-468E-BE43-FE63E383AA3A}'
$cdSection = $sln.Substring($cdProjectStart, $cdSectionEnd - $cdProjectStart)
if ($cdSection -notmatch [regex]::Escape($ifwGuid)) {
    $sln = $sln.Insert($cdSectionEnd, "`t`t$ifwGuid = $ifwGuid`r`n")
    $sln | Set-Content -LiteralPath $solution -Encoding utf8
}

# FAST_Types contains CableDyn_Types, so every downstream Visual Studio project
# that directly consumes OpenFAST-Prelib also needs CableDyn's module directory.
# Intel Fortran solution dependencies do not propagate module search paths
# transitively. Add the direct dependency to those consumers rather than relying
# on build order alone.
$sln = Get-Content -LiteralPath $solution -Raw
$prelibGuid = '{FE80CE9A-7E16-476D-B63A-F9F870ACB662}'
$projectPattern = '(?ms)^Project\(.*?^EndProject\r*$'
$sln = [regex]::Replace($sln, $projectPattern, {
    param($match)
    $block = $match.Value
    if ($block -notmatch [regex]::Escape($prelibGuid) -or
        $block -match '= "CableDyn",' -or
        $block -match [regex]::Escape($cdGuid)) {
        return $block
    }
    $end = $block.LastIndexOf("`tEndProjectSection", [StringComparison]::Ordinal)
    if ($end -lt 0) { throw 'Prelib consumer has no dependency section' }
    return $block.Insert($end, "`t`t$cdGuid = $cdGuid`r`n")
})
$sln | Set-Content -LiteralPath $solution -Encoding utf8

# The adapter project is linked through the normal solution dependency graph.
# The independently built CableDyn core is not a solution project, so add it
# explicitly to every OpenFAST link configuration. The static-release core is
# compiled with /Qipo and links only in configurations with whole-program
# optimisation (Release|x64, which the release builds).
[xml]$vf = Get-Content -LiteralPath $openfastProject -Raw
foreach ($configuration in $vf.VisualStudioProject.Configurations.Configuration) {
    $linker = @($configuration.Tool | Where-Object { $_.Name -eq 'VFLinkerTool' })[0]
    if ($null -eq $linker) { throw "OpenFAST linker tool missing for $($configuration.Name)" }
    $existing = [string]$linker.AdditionalDependencies
    foreach ($library in @($coreLibrary) + $LinkLibraries) {
        if ($existing -notlike "*$library*") {
            $existing = ($existing + ' "' + $library + '"').Trim()
        }
    }
    $linker.SetAttribute('AdditionalDependencies', $existing)

    # Merge the UTF-8 active-code-page manifest into openfast.exe (the linker's own
    # asInvoker manifest is kept), so input and output files open in folders whose
    # names are outside the system ANSI code page.
    $manifestTool = @($configuration.Tool | Where-Object { $_.Name -eq 'VFManifestTool' })[0]
    if ($null -eq $manifestTool) {
        $manifestTool = $vf.CreateElement('Tool')
        $manifestTool.SetAttribute('Name', 'VFManifestTool')
        [void]$configuration.AppendChild($manifestTool)
    }
    $manifests = [string]$manifestTool.GetAttribute('AdditionalManifestFiles')
    if ($manifests -notlike "*$utf8Manifest*") {
        $manifests = (($manifests, $utf8Manifest) | Where-Object { $_ }) -join ';'
    }
    $manifestTool.SetAttribute('AdditionalManifestFiles', $manifests)
}
$settings = New-Object Xml.XmlWriterSettings
$settings.Indent = $true
$settings.Encoding = New-Object Text.UTF8Encoding($false)
$writer = [Xml.XmlWriter]::Create($openfastProject, $settings)
try { $vf.Save($writer) } finally { $writer.Dispose() }

# The pre-build step runs in vs-build\modules; the VersionInfo project includes the header
# through GIT_INCLUDE_FILE='..\gitVersionInfo.h'.
$versionScript = @(
    '@ECHO off'
    'REM Written by CableDyn integration/openfast/integrate_openfast_vs_solution.ps1: the OpenFAST'
    'REM base and the CableDyn version this executable is built from.'
    ">..\gitVersionInfo.h ECHO $versionDefine"
    'EXIT /B 0'
) -join "`r`n"
[IO.File]::WriteAllText((Join-Path $OpenFASTRoot 'vs-build\CreateGitVersion.bat'), "$versionScript`r`n",
                        [Text.Encoding]::ASCII)
$versionHeader = Join-Path $OpenFASTRoot 'vs-build\gitVersionInfo.h'
if (-not (Test-Path -LiteralPath $versionHeader) -or
    (Get-Content -LiteralPath $versionHeader -Raw) -ne "$versionDefine`r`n") {
    [IO.File]::WriteAllText($versionHeader, "$versionDefine`r`n", [Text.Encoding]::ASCII)
}

Write-Host "PASS: CableDyn added to OpenFAST Visual Studio Release solution (version $versionStamp)"
