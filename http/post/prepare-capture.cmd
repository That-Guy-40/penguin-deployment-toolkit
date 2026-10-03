@echo off
rem prepare-capture.cmd - turn this installed system into a reference image
rem ready to capture. Run (elevated) by firstlogon.cmd when the machine's cfg
rem says REFERENCE=yes; Phase 3's role configuration will run before it.
rem
rem   1. a provenance stamp inside the image (%WINDIR%\pdt-image.txt).
rem   2. sysprep /generalize /oobe: remove this machine's identity, so that a
rem      machine deployed from the image runs specialize and OOBE as a new one.
rem   3. a FULL shutdown (not fast startup), leaving the disk consistent.
rem WinRE is left alone. Its Winre.wim sits on the recovery partition, not on
rem the Windows volume ("reagentc /disable" does not move it back: verified),
rem so the captured image has none; step 45-winre takes it from the server
rem instead (images/<name>.winre.wim, put there by bin/stage-image).
rem Then: set MODE=capture in the cfg and PXE-boot it (bin/vm-boot <vm> --pxe).
setlocal EnableExtensions
call "%~dp0id.cmd"
call "%~dp0beacon.cmd" prepare-capture start
set OUT=%~dp0prepare-capture.txt
set SPDIR=%WINDIR%\System32\Sysprep
set RESULT=fail

> "%OUT%" echo prepare-capture %DATE% %TIME%
rem The stamp names the role and the apps list (its SHA-256) baked into this image.
set APPSHASH=-
if exist "%~dp0role\role.cfg" for /f "usebackq eol=# tokens=1,* delims==" %%a in ("%~dp0role\role.cfg") do (
  if /i "%%a"=="APPS" for /f "delims=" %%h in ('certutil -hashfile "%~dp0role\%%b" SHA256 ^| find /v ":"') do set "APPSHASH=%%h"
)
if not defined ROLE set ROLE=-
> "%WINDIR%\pdt-image.txt" echo reference %ID% run %RUN% role %ROLE% apps %APPSHASH%

rem winget's source index (Microsoft.Winget.Source) is installed per user the
rem first time winget runs and is never provisioned; sysprep then refuses to
rem generalize (0x80073cf2 "installed for a user, but not provisioned for all
rem users": verified). Remove it; winget fetches it again when next used. Any
rem other such package makes sysprep fail the same way, and its log names it.
>> "%OUT%" echo === per-user Appx packages that are not provisioned (sysprep refuses these)
powershell -NoProfile -Command "$p = (Get-AppxProvisionedPackage -Online).DisplayName; Get-AppxPackage | Where-Object { $_.SignatureKind -ne 'System' -and -not $_.IsFramework -and $p -notcontains $_.Name } | ForEach-Object { $_.PackageFullName }" >> "%OUT%" 2>&1
powershell -NoProfile -Command "Get-AppxPackage Microsoft.Winget.Source | Remove-AppxPackage" >> "%OUT%" 2>&1
rem Never capture generated passwords (firstlogon removes the file; be sure).
if exist "%~dp0users-out.txt" del /f /q "%~dp0users-out.txt"
del "%SPDIR%\Sysprep_succeeded.tag" 2>nul
start "" /wait "%SPDIR%\sysprep.exe" /generalize /oobe /quit /quiet
>> "%OUT%" echo sysprep exit code %errorlevel%
if not exist "%SPDIR%\Sysprep_succeeded.tag" (
  set BEACON_RETRY=1
  call "%~dp0beacon.cmd" prepare-capture fail "msg=sysprep did not succeed; see sysprep-setuperr.log in the uploads"
  goto :upload
)
set RESULT=ok
rem Best effort only: generalizing removes the network adapter, so this
rem usually cannot be delivered. The verdict is read from the disk at capture
rem time (70-capture reports the image state).
set BEACON_RETRY=1
call "%~dp0beacon.cmd" prepare-capture ok

:upload
curl.exe -sS -T "%OUT%" "%SRV%/uploads/%ID%/%RUN%/prepare-capture.txt" -o nul --max-time 60
for %%f in (setupact.log setuperr.log) do (
  if exist "%SPDIR%\Panther\%%f" curl.exe -sS -T "%SPDIR%\Panther\%%f" "%SRV%/uploads/%ID%/%RUN%/sysprep-%%f" -o nul --max-time 120
)
if "%RESULT%"=="ok" shutdown /s /t 5 /f
