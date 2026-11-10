@echo off
rem Offline hull-builder: drawing PDF -> complete moulded-line ship XML + BUILD_REPORT.md (decks, walls, frames)
rem usage: run_offline.bat DRAWING.pdf OUTDIR [settings.json] [--raster]
set PDF=%1
set OUT=%2
if "%3"=="" (set ST=project_settings.json) else (set ST=%3)
python -m deckrules.build_ship "%PDF%" --settings "%ST%" --out "%OUT%" %4
