@echo off
rem check-apps.cmd - POST script for the Phase 3 acceptance: is the role's
rem software present on a machine deployed from the role image, with no role
rem of its own? (The image's stamp arrives with the firstlogon beacon.)
call "%~dp0id.cmd"
set SEVENZIP=no
set NPP=no
set STALEROLE=no
if exist "%ProgramFiles%\7-Zip\7z.exe" set SEVENZIP=yes
if exist "%ProgramFiles%\Notepad++\notepad++.exe" set NPP=yes
if exist "%~dp0role\role.cfg" set STALEROLE=yes
set WG=no
%LOCALAPPDATA%\Microsoft\WindowsApps\winget.exe --version >nul 2>&1 && set WG=yes
call "%~dp0beacon.cmd" apps-present ok "sevenzip=%SEVENZIP%" "npp=%NPP%" "winget=%WG%" "stale_role=%STALEROLE%"
