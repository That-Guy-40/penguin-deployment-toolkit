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
> "%WINDIR%\pdt-image.txt" echo reference %ID% run %RUN%

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
