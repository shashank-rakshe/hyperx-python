@ECHO OFF
REM SPDX-License-Identifier: Apache-2.0
REM Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
REM Minimal Sphinx build script for CableDyn docs on Windows.
REM Usage:  doc\make.bat html   (output in doc\_build\html)

pushd %~dp0

if "%SPHINXBUILD%" == "" (
	set SPHINXBUILD=sphinx-build
)
set SOURCEDIR=.
set BUILDDIR=_build
set SPHINXOPTS=-W --keep-going -n

if "%1" == "" goto help

%SPHINXBUILD% -M %1 %SOURCEDIR% %BUILDDIR% %SPHINXOPTS% %O%
goto end

:help
%SPHINXBUILD% -M help %SOURCEDIR% %BUILDDIR% %SPHINXOPTS% %O%

:end
popd
