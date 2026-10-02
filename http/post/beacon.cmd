@echo off
rem beacon.cmd <step> <ev> ["key=value" ...]
rem Runs in the INSTALLED Windows from C:\pdt\. Continues the run the WinPE
rem task sequence started: id.cmd next to this file carries SRV, ID and RUN.
rem Retries, because at boot the network may not be up yet.
setlocal EnableExtensions
call "%~dp0id.cmd"
set "B=--data-urlencode id=%ID% --data-urlencode run=%RUN% --data-urlencode step=%~1 --data-urlencode ev=%~2"
shift
shift
:more
if "%~1"=="" goto :send
set "B=%B% --data-urlencode "%~1""
shift
goto :more
:send
curl.exe -sS -G "%SRV%/beacon" %B% -o nul --max-time 15 --retry 20 --retry-delay 3 --retry-all-errors
