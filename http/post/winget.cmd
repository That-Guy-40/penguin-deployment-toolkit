@echo off
rem winget.cmd - called by firstlogon.cmd when the machine's role has APPS=.
rem 1. Make winget usable now: an image built from install media has no App
rem    Installer at first logon (not even staged). The release's msixbundle and
rem    the x64 dependencies it ships are served from this server
rem    (post/winget/, put there by bin/fetch-tools winget; files.txt lists them).
rem    Provisioned for all users WITH its licence (so sysprep of a reference
rem    machine accepts it) and registered for the current user (so it works now).
rem 2. Install each winget id in the role's apps list (one per line, # comments).
rem Beacons: winget ok|fail version=   apps ok|fail installed= failed= msg=
rem Output: C:\pdt\winget.txt and winget's own logs, both uploaded.
setlocal EnableExtensions EnableDelayedExpansion
call "%~dp0id.cmd"
set APPS=%~1
set OUT=%~dp0winget.txt
set D=%TEMP%\pdt-winget
set WG=%LOCALAPPDATA%\Microsoft\WindowsApps\winget.exe
mkdir "%D%" 2>nul
> "%OUT%" echo winget.cmd %DATE% %TIME% apps=%APPS%

>> "%OUT%" echo === download post/winget/
curl.exe -sS -f -o "%D%\files.txt" "%SRV%/post/winget/files.txt" >> "%OUT%" 2>&1 || goto :nofiles
set DEPS=
set BUNDLE=
for /f "usebackq eol=# delims=" %%f in ("%D%\files.txt") do (
  curl.exe -sS -f -o "%D%\%%f" "%SRV%/post/winget/%%f" >> "%OUT%" 2>&1 || goto :nofiles
  if /i "%%~xf"==".appx" set "DEPS=!DEPS!,'%D%\%%f'"
  if /i "%%~xf"==".msixbundle" set "BUNDLE=%D%\%%f"
)
curl.exe -sS -f -o "%D%\License1.xml" "%SRV%/post/winget/License1.xml" >> "%OUT%" 2>&1 || goto :nofiles
if not defined BUNDLE goto :nofiles
set "DEPS=%DEPS:~1%"

>> "%OUT%" echo === Add-AppxProvisionedPackage (all users, licensed) + Add-AppxPackage (this user)
powershell -NoProfile -Command "$ErrorActionPreference='Stop'; $d=@(%DEPS%); Add-AppxProvisionedPackage -Online -PackagePath '%BUNDLE%' -DependencyPackagePath $d -LicensePath '%D%\License1.xml' | Out-Null; Add-AppxPackage -Path '%BUNDLE%' -DependencyPath $d" >> "%OUT%" 2>&1
set ADD_RC=%errorlevel%
>> "%OUT%" echo add rc %ADD_RC%
>> "%OUT%" echo === winget --version
set WGVER=
"%WG%" --version > "%D%\version.txt" 2>>"%OUT%"
set /p WGVER=<"%D%\version.txt"
>> "%OUT%" echo %WGVER%
if not defined WGVER (
  call "%~dp0beacon.cmd" winget fail "msg=winget not usable after bootstrap (add rc %ADD_RC%)"
  goto :upload
)
call "%~dp0beacon.cmd" winget ok "version=%WGVER%"

rem --- the role's apps ----------------------------------------------------------
if not defined APPS goto :upload
if not exist "%APPS%" (
  call "%~dp0beacon.cmd" apps fail "msg=apps list %APPS% missing"
  goto :upload
)
set INSTALLED=
set FAILED=
for /f "usebackq eol=# tokens=1" %%a in ("%APPS%") do (
  >> "%OUT%" echo === winget install %%a
  "%WG%" install --id %%a -e --silent --accept-package-agreements --accept-source-agreements --disable-interactivity >> "%OUT%" 2>&1
  set RC=!errorlevel!
  >> "%OUT%" echo rc !RC!
  rem 0: installed. -1978335189 (0x8A15002B): no newer version, already there.
  if "!RC!"=="0" (set "INSTALLED=!INSTALLED!,%%a") else if "!RC!"=="-1978335189" (set "INSTALLED=!INSTALLED!,%%a") else set "FAILED=!FAILED!,%%a(!RC!)"
)
if defined INSTALLED set "INSTALLED=%INSTALLED:~1%"
if defined FAILED set "FAILED=%FAILED:~1%"
if defined FAILED (
  call "%~dp0beacon.cmd" apps fail "installed=%INSTALLED%" "failed=%FAILED%" "msg=see winget.txt in the uploads"
) else (
  call "%~dp0beacon.cmd" apps ok "installed=%INSTALLED%" "failed="
)
goto :upload

:nofiles
call "%~dp0beacon.cmd" winget fail "msg=post/winget/ incomplete on the server; run bin/fetch-tools winget"

:upload
curl.exe -sS -T "%OUT%" "%SRV%/uploads/%ID%/%RUN%/winget.txt" -o nul --max-time 60
set DIAG=%LOCALAPPDATA%\Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\DiagOutputDir
if exist "%DIAG%" (
  copy /y /b "%DIAG%\*.log" "%~dp0winget-diag.log" >nul 2>&1
  if exist "%~dp0winget-diag.log" curl.exe -sS -T "%~dp0winget-diag.log" "%SRV%/uploads/%ID%/%RUN%/winget-diag.log" -o nul --max-time 60
)
exit /b 0
