@echo off
rem spike-probe.cmd - POST script for the 2026-10-02 spikes. Answers two open
rem questions from the installed system at first logon:
rem   1. is winget usable at first logon, and can it install something?
rem   2. can a boot-time scheduled task report every boot?
setlocal EnableExtensions
call "%~dp0id.cmd"
set OUT=%~dp0probe.txt
> "%OUT%" echo === where winget
where winget >> "%OUT%" 2>&1
set WHERE_RC=%errorlevel%
>> "%OUT%" echo === winget --version
winget --version >> "%OUT%" 2>&1
set VER_RC=%errorlevel%
set REGISTERED=no
if "%VER_RC%"=="0" goto :install
>> "%OUT%" echo === registering App Installer for this user
powershell -NoProfile -Command "Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe" >> "%OUT%" 2>&1
set REGISTERED=yes
winget --version >> "%OUT%" 2>&1
set VER_RC=%errorlevel%
:install
>> "%OUT%" echo === winget install 7zip.7zip
winget install --id 7zip.7zip -e --silent --accept-package-agreements --accept-source-agreements --disable-interactivity >> "%OUT%" 2>&1
set INSTALL_RC=%errorlevel%
set SEVENZIP=no
if exist "%ProgramFiles%\7-Zip\7z.exe" set SEVENZIP=yes
set VERDICT=fail
if "%SEVENZIP%"=="yes" set VERDICT=ok
call "%~dp0beacon.cmd" winget %VERDICT% "where_rc=%WHERE_RC%" "version_rc=%VER_RC%" "registered=%REGISTERED%" "install_rc=%INSTALL_RC%" "sevenzip=%SEVENZIP%"

>> "%OUT%" echo === schtasks: a task at every boot
schtasks /create /f /sc onstart /ru SYSTEM /rl highest /tn PDT-boot /tr "cmd /c C:\pdt\beacon.cmd boot ok" >> "%OUT%" 2>&1
set TASK_RC=%errorlevel%
set VERDICT=fail
if "%TASK_RC%"=="0" set VERDICT=ok
call "%~dp0beacon.cmd" boot-task %VERDICT% "rc=%TASK_RC%"
curl.exe -sS -T "%OUT%" "%SRV%/uploads/%ID%/%RUN%/probe.txt" -o nul --max-time 60
