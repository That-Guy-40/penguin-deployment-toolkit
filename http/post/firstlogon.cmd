@echo off
rem firstlogon.cmd - run once by unattend.xml (FirstLogonCommands) from C:\pdt\.
rem Reports that the first logon was reached, checks that the recovery
rem environment is enabled AND lives on the recovery partition, and pushes
rem Setup's own logs. Phase 3 hangs the winget / role configuration off this file.
setlocal EnableExtensions EnableDelayedExpansion
call "%~dp0id.cmd"

set BUILD=
for /f "tokens=3" %%a in ('reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v CurrentBuild ^| find "CurrentBuild"') do set BUILD=%%a
for /f "tokens=3" %%a in ('reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v UBR ^| find "UBR"') do set /a UBR=%%a
rem An image captured from a reference machine carries a stamp of its origin.
set IMAGEFROM=
if exist "%WINDIR%\pdt-image.txt" set /p IMAGEFROM=<"%WINDIR%\pdt-image.txt"
rem Is Secure Boot enforcing on this machine? (True / False / empty on firmware without it)
set SECUREBOOT=
for /f %%s in ('powershell -NoProfile -Command "try { Confirm-SecureBootUEFI } catch { 'unsupported' }"') do set SECUREBOOT=%%s
call "%~dp0beacon.cmd" firstlogon ok "host=%COMPUTERNAME%" "user=%USERNAME%" "build=%BUILD%.%UBR%" "secureboot=%SECUREBOOT%" "image=%IMAGEFROM%"

rem --- WinRE: enabled, and not sitting on the Windows partition ---------------
reagentc /info > "%~dp0reagentc.txt" 2>&1
set RESTATUS=
set RELOC=
for /f "tokens=1,* delims=:" %%a in ('findstr /c:"Windows RE status" "%~dp0reagentc.txt"') do set "RESTATUS=%%b"
for /f "tokens=1,* delims=:" %%a in ('findstr /c:"Windows RE location" "%~dp0reagentc.txt"') do set "RELOC=%%b"
if defined RESTATUS set "RESTATUS=%RESTATUS: =%"
if defined RELOC set "RELOC=%RELOC: =%"
set CPART=
for /f %%p in ('powershell -NoProfile -Command "(Get-Partition -DriveLetter C).PartitionNumber"') do set CPART=%%p
set WINRE=ok
if /i not "%RESTATUS%"=="Enabled" set WINRE=fail
if not defined RELOC set WINRE=fail
if defined RELOC if defined CPART (echo %RELOC% | find /i "partition%CPART%\" >nul && set WINRE=fail)
if not defined CPART set WINRE=fail
call "%~dp0beacon.cmd" winre %WINRE% "status=%RESTATUS%" "location=%RELOC%" "windows_partition=%CPART%"

curl.exe -sS -T "%~dp0reagentc.txt" "%SRV%/uploads/%ID%/%RUN%/reagentc.txt" -o nul --max-time 60
for %%f in (setupact.log setuperr.log) do (
  if exist "%WINDIR%\Panther\%%f" curl.exe -sS -T "%WINDIR%\Panther\%%f" "%SRV%/uploads/%ID%/%RUN%/panther-%%f" -o nul --max-time 120
)

rem --- POST=<file> in the cfg: this machine's (or model's) own post-install -----
if exist "%~dp0post.cmd" call "%~dp0post.cmd"

rem --- reference machine: generalize and shut down, ready for MODE=capture -----
if /i "%REFERENCE%"=="yes" call "%~dp0prepare-capture.cmd"
