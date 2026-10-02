@echo off
rem beacon.cmd <step> <ev> ["key=value" ...]   (quote every key=value)
rem One progress event to the server: GET /beacon?id=..&run=..&step=..&ev=..
rem Used in WinPE (X:\pdt\, environment already loaded by env.cmd) and in the
rem installed Windows (C:\pdt\, where id.cmd next to this file carries SRV, ID
rem and RUN so the installed system continues the run WinPE started).
if not defined SRV call "%~dp0id.cmd"
if not defined BEACON_RETRY set BEACON_RETRY=20
set "B=--data-urlencode id=%ID% --data-urlencode run=%RUN% --data-urlencode step=%~1 --data-urlencode ev=%~2"
if defined LOG >>%LOG% echo [pdt] beacon %~1 %~2
shift
shift
:more
if "%~1"=="" goto :send
set "B=%B% --data-urlencode "%~1""
shift
goto :more
:send
curl.exe -sS -G "%SRV%/beacon" %B% -o nul --max-time 15 --retry %BEACON_RETRY% --retry-delay 3 --retry-all-errors
exit /b 0
