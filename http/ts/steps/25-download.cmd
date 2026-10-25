@echo off
rem 25-download - fetch the OS image over HTTP onto the new Windows partition
rem and prove it is the file the server describes (ts/verified.cmd: SHA-256
rem against images/<name>.json with tools/pdt-sha256.exe) before anything is
rem applied. A failure deletes the download; only a match writes
rem X:\pdt\image.verified, which 30-apply demands: a resumed "deploy 30" never
rem applies an unverified file. bin/lint --deep checks the same pair on the server.
setlocal EnableExtensions EnableDelayedExpansion
call X:\pdt\env.cmd
del %PDT%\image.verified 2>nul
if /i not "%IMAGE:~-4%"==".wim" (>%PDT%\step.msg echo IMAGE=%IMAGE% does not end in .wim: no sidecar name can be derived& exit /b 1)
call %PDT%\verified.cmd images/%IMAGE% images/%IMAGE:.wim=.json% W:\image.wim || exit /b !errorlevel!
copy /y %PDT%\verified.out %PDT%\image.verified >nul
copy /y %PDT%\verified.msg %PDT%\step.msg >nul
exit /b 0
