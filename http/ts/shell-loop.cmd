@echo off
rem shell-loop.cmd - a remote shell over HTTP, for machines with no usable
rem screen or keyboard. Started in the background by deploy.cmd once per boot
rem and alive as long as WinPE is (a prompt, a stopped step, a failed step).
rem
rem Every 2 s: GET cmd/<id>/<run>/<n>.cmd from the server (bin/shell writes
rem it; n counts up from 1 within this run, so nothing runs twice and nothing
rem from an earlier boot runs at all). If it is there: run it with cmd /c,
rem PUT its output as uploads/<id>/<run>/cmd-<n>.out, n+1. Also, while
rem tools/pdt-screen.exe is injected, a screenshot every PDT_SCREEN_EVERY
rem (default 5) seconds as uploads/<id>/<run>/screen.bmp (bin/screen shows it).
rem
rem Trust: whoever can write to http/ on the server already runs code as
rem SYSTEM on every machine that boots (that is what deploy.cmd is); this
rem adds no new party and no listening port. Kill switch: bin/shell --off,
rem which writes <n>.cmd containing "exit /b 42": the loop ends.
setlocal EnableExtensions EnableDelayedExpansion
call %PDT%\env.cmd
set N=1
set TICK=0
if not defined PDT_SCREEN_EVERY set PDT_SCREEN_EVERY=5
rem The screen pusher is optional: built by bin/build-tools (mingw-w64) and
rem served from tools/; without it this loop is just the shell.
set SCREEN=%PDT%\pdt-screen.exe
if not exist "%SCREEN%" %CURL% -f -o "%SCREEN%" "%SRV%/tools/pdt-screen.exe" >nul 2>&1 & rem [optional]
:loop
%CURL% -f -o %PDT%\cmd-%N%.cmd "%SRV%/cmd/%ID%/%RUN%/%N%.cmd" >nul 2>&1
if exist %PDT%\cmd-%N%.cmd (
  >>%LOG% echo [pdt] shell: running cmd %N%
  cmd /c %PDT%\cmd-%N%.cmd > %PDT%\cmd-%N%.out 2>&1
  set RC=!errorlevel!
  >>%PDT%\cmd-%N%.out echo [pdt] exit code !RC!
  %CURL% -T %PDT%\cmd-%N%.out "%SRV%/uploads/%ID%/%RUN%/cmd-%N%.out" -o nul --max-time 60 >nul 2>&1
  if "!RC!"=="42" goto :off
  set /a N+=1
)
set /a TICK+=2
if exist "%SCREEN%" if !TICK! geq %PDT_SCREEN_EVERY% (
  set TICK=0
  "%SCREEN%" %PDT%\screen.bmp >nul 2>&1 && %CURL% -T %PDT%\screen.bmp "%SRV%/uploads/%ID%/%RUN%/screen.bmp" -o nul --max-time 30 >nul 2>&1
)
ping -n 3 127.0.0.1 >nul
goto :loop
:off
>>%LOG% echo [pdt] shell: switched off by cmd %N%
exit /b 0
