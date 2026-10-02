@echo off
rem winget-bootstrap-probe.cmd - POST script for the 2026-10-02 spikes.
rem winget is absent at first logon on an image built from UUP dump (App
rem Installer is not even staged). Does installing the current release with
rem the dependencies it ships (DesktopAppInstaller_Dependencies.zip: VCLibs,
rem UI.Xaml, WindowsAppRuntime) make it usable right there, and can it then
rem install something? Downloads straight from GitHub: a spike, not how
rem Phase 3 should fetch them (pin and serve them from this server).
setlocal EnableExtensions
call "%~dp0id.cmd"
set OUT=%~dp0winget-bootstrap.txt
set D=%TEMP%\pdt-winget
set REL=https://github.com/microsoft/winget-cli/releases/download/v1.29.380
mkdir "%D%" 2>nul
> "%OUT%" echo === download
curl.exe -sSL -o "%D%\deps.zip" %REL%/DesktopAppInstaller_Dependencies.zip >> "%OUT%" 2>&1
curl.exe -sSL -o "%D%\winget.msixbundle" %REL%/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle >> "%OUT%" 2>&1
tar -xf "%D%\deps.zip" -C "%D%" >> "%OUT%" 2>&1
dir /s /b "%D%" >> "%OUT%"
>> "%OUT%" echo === Add-AppxPackage with -DependencyPath x64\*.appx
powershell -NoProfile -Command "$ErrorActionPreference='Stop'; $deps = Get-ChildItem '%D%\x64\*.appx' | ForEach-Object FullName; Add-AppxPackage -Path '%D%\winget.msixbundle' -DependencyPath $deps" >> "%OUT%" 2>&1
set ADD_RC=%errorlevel%
set WG=%LOCALAPPDATA%\Microsoft\WindowsApps\winget.exe
>> "%OUT%" echo === winget --version
"%WG%" --version >> "%OUT%" 2>&1
set VER_RC=%errorlevel%
>> "%OUT%" echo === winget install 7zip.7zip
"%WG%" install --id 7zip.7zip -e --silent --accept-package-agreements --accept-source-agreements --disable-interactivity >> "%OUT%" 2>&1
set INSTALL_RC=%errorlevel%
set SEVENZIP=no
if exist "%ProgramFiles%\7-Zip\7z.exe" set SEVENZIP=yes
set VERDICT=fail
if "%SEVENZIP%"=="yes" set VERDICT=ok
call "%~dp0beacon.cmd" winget-bootstrap %VERDICT% "add_rc=%ADD_RC%" "version_rc=%VER_RC%" "install_rc=%INSTALL_RC%" "sevenzip=%SEVENZIP%"
curl.exe -sS -T "%OUT%" "%SRV%/uploads/%ID%/%RUN%/winget-bootstrap.txt" -o nul --max-time 60
