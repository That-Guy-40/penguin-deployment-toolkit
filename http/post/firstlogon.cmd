@echo off
rem firstlogon.cmd - run once by unattend.xml (FirstLogonCommands) from C:\pdt\.
rem Phase 1: report that the desktop was reached and push Setup's own logs.
rem Phase 3 hangs the winget / role configuration off this file.
setlocal EnableExtensions
call "%~dp0id.cmd"
call "%~dp0beacon.cmd" firstlogon ok "host=%COMPUTERNAME%" "user=%USERNAME%"
for %%f in (setupact.log setuperr.log) do (
  if exist "%WINDIR%\Panther\%%f" curl.exe -sS -T "%WINDIR%\Panther\%%f" "%SRV%/uploads/%ID%/%RUN%/panther-%%f" -o nul --max-time 120
)
