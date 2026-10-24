@echo off
rem 25-download - fetch the OS image over HTTP onto the new Windows partition,
rem then prove it is the file the server describes before anything is applied:
rem SHA-256 of image.wim against the "sha256" in images/<name>.json (the sidecar
rem bin/stage-image writes; bin/lint --deep checks the same pair on the server).
rem WinPE has no certutil and no PowerShell, so the hash is tools/pdt-sha256.exe,
rem built from tools-src/ by bin/build-tools; 15-preflight checks it is served.
rem Integrity, not authentication: hasher, sidecar and image all come from the
rem same server, like boot.wim itself.
rem Any failure deletes the download, and only a match writes X:\pdt\image.verified,
rem which 30-apply demands: a resumed "deploy 30" never applies an unverified file.
setlocal EnableExtensions EnableDelayedExpansion
call X:\pdt\env.cmd
del %PDT%\image.verified 2>nul
if /i not "%IMAGE:~-4%"==".wim" (>%PDT%\step.msg echo IMAGE=%IMAGE% does not end in .wim: no sidecar name can be derived& exit /b 1)
set HASHER=%PDT%\pdt-sha256.exe
if not exist "%HASHER%" (
  %CURL% -f -o "%HASHER%.part" "%SRV%/tools/pdt-sha256.exe" || (>%PDT%\step.msg echo tools/pdt-sha256.exe is not on the server: run bin/build-tools& exit /b 1)
  move /y "%HASHER%.part" "%HASHER%" >nul
)
rem Smoke test: with no arguments the hasher must exit 2 (usage). Anything else is
rem a binary that did not run, which must not be mistaken for a mismatch.
"%HASHER%" >nul 2>&1
if not "!errorlevel!"=="2" (>%PDT%\step.msg echo X:\pdt\pdt-sha256.exe does not run ^(exit !errorlevel!, expected 2^): a damaged download? delete it and re-run& exit /b 1)
%CURL% -f -o %PDT%\image.json "%SRV%/images/%IMAGE:.wim=.json%" || (>%PDT%\step.msg echo no sidecar images/%IMAGE:.wim=.json% on the server: the image cannot be verified& exit /b 1)
%CURL% -f --retry 2 -o W:\image.wim "%SRV%/images/%IMAGE%"
set RC=!errorlevel!
if not "!RC!"=="0" (del W:\image.wim 2>nul & >%PDT%\step.msg echo curl exit !RC! fetching images/%IMAGE%: partial download deleted& exit /b !RC!)
"%HASHER%" --check %PDT%\image.json W:\image.wim >%PDT%\image.sha256
set RC=!errorlevel!
type %PDT%\image.sha256
if not "!RC!"=="0" goto :bad
set HASH=
for /f "tokens=1" %%h in (%PDT%\image.sha256) do if not defined HASH set HASH=%%h
>%PDT%\image.verified echo !HASH! W:\image.wim
>%PDT%\step.msg echo sha256 !HASH! matches images/%IMAGE:.wim=.json%
exit /b 0
:bad
del W:\image.wim
if "!RC!"=="1" (>%PDT%\step.msg echo image.wim does not match the sha256 in images/%IMAGE:.wim=.json%: download deleted, nothing applied) else (>%PDT%\step.msg echo pdt-sha256 exit !RC!, 4 = the sidecar has no usable sha256, 3 = a file could not be read: download deleted, nothing applied)
exit /b !RC!
