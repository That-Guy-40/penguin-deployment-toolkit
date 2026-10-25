@echo off
rem verified.cmd <path> <sidecar> <dest> - fetch <path> from the server to <dest>,
rem then prove it is the file the server describes: its SHA-256 against the
rem "sha256" in <sidecar> (the .json beside every image and pack, written by
rem bin/stage-image, bin/pack-drivers, bin/pack-updates). One mechanism for every
rem large download of the task sequence: the OS image (25-download), update and
rem driver packs (35-updates, 40-drivers), the recovery image (45-winre).
rem   call %PDT%\verified.cmd images/base.wim images/base.json W:\image.wim || exit /b !errorlevel!
rem WinPE has no certutil and no PowerShell: the hash is tools/pdt-sha256.exe,
rem built from tools-src/ by bin/build-tools (15-preflight checks it is served).
rem Integrity, not authentication: hasher, sidecar and file all come from the
rem same server, like boot.wim itself.
rem Any failure deletes <dest> and leaves one line in step.msg; exit code: curl's
rem for a failed download, pdt-sha256's otherwise (1 mismatch, 3 unreadable,
rem 4 the sidecar has no usable sha256), 2 for a hasher that does not run.
rem Success leaves the hasher's output in X:\pdt\verified.out (first token: the
rem hash) and "sha256 <hex> matches <sidecar>" in X:\pdt\verified.msg for the
rem caller's step.msg.
setlocal EnableExtensions EnableDelayedExpansion
call X:\pdt\env.cmd
set "WHAT=%~1"
set "SIDECAR=%~2"
set "DEST=%~3"
del %PDT%\verified.msg %PDT%\verified.out 2>nul
if "%DEST%"=="" (>%PDT%\step.msg echo verified.cmd needs ^<path^> ^<sidecar^> ^<dest^>& exit /b 2)
set HASHER=%PDT%\pdt-sha256.exe
if not exist "%HASHER%" (
  %CURL% -f -o "%HASHER%.part" "%SRV%/tools/pdt-sha256.exe" || (>%PDT%\step.msg echo tools/pdt-sha256.exe is not on the server: run bin/build-tools& exit /b 2)
  move /y "%HASHER%.part" "%HASHER%" >nul
)
rem Smoke test: with no arguments the hasher must exit 2 (usage). Anything else is
rem a binary that did not run, which must not be mistaken for a mismatch.
"%HASHER%" >nul 2>&1
if not "!errorlevel!"=="2" (>%PDT%\step.msg echo X:\pdt\pdt-sha256.exe does not run ^(exit !errorlevel!, expected 2^): a damaged download? delete it and re-run& exit /b 2)
rem The sidecar's local name keeps its path (images/base.json -> images-base.json).
set "SC=%PDT%\%SIDECAR:/=-%"
%CURL% -f -o "%SC%" "%SRV%/%SIDECAR%" || (>%PDT%\step.msg echo no sidecar %SIDECAR% on the server: %WHAT% cannot be verified& exit /b 4)
%CURL% -f --retry 2 -o "%DEST%" "%SRV%/%WHAT%"
set RC=!errorlevel!
if not "!RC!"=="0" (del "%DEST%" 2>nul & >%PDT%\step.msg echo curl exit !RC! fetching %WHAT%: partial download deleted& exit /b !RC!)
"%HASHER%" --check "%SC%" "%DEST%" >%PDT%\verified.out
set RC=!errorlevel!
type %PDT%\verified.out
if not "!RC!"=="0" goto :bad
set HASH=
for /f "tokens=1" %%h in (%PDT%\verified.out) do if not defined HASH set HASH=%%h
>%PDT%\verified.msg echo sha256 !HASH! matches %SIDECAR%
exit /b 0
:bad
del "%DEST%"
if "!RC!"=="1" (>%PDT%\step.msg echo %WHAT% does not match the sha256 in %SIDECAR%: download deleted) else (>%PDT%\step.msg echo pdt-sha256 exit !RC! on %WHAT%, 4 = %SIDECAR% has no usable sha256, 3 = a file could not be read: download deleted)
exit /b !RC!
