@echo off
rem firstlogon.cmd - run once by unattend.xml (FirstLogonCommands) from C:\pdt\.
rem Reports that the first logon was reached, checks that the recovery
rem environment is enabled AND lives on the recovery partition, and pushes
rem Setup's own logs. Then the role (C:\pdt\role\, put there by 60-unattend):
rem winget and its apps, the fast-startup policy; the every-boot probe; the
rem role's and the machine's post scripts; the "deployed" verdict; and on a
rem reference machine, prepare-capture.
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

rem --- the role: roles/<ROLE>/role.cfg, fetched by 60-unattend ------------------
set APPS=
set ROLE_POST=
set FASTSTARTUP=
if exist "%~dp0role\role.cfg" for /f "usebackq eol=# tokens=1,* delims==" %%a in ("%~dp0role\role.cfg") do (
  if /i "%%a"=="APPS" set "APPS=%~dp0role\%%b"
  if /i "%%a"=="POST" set "ROLE_POST=%~dp0role\%%b"
  if /i "%%a"=="FASTSTARTUP" set "FASTSTARTUP=%%b"
)
if defined APPS call "%~dp0winget.cmd" "%APPS%"
rem FASTSTARTUP=off: no hibernation, so every shutdown is a real shutdown and
rem the next power-on a real boot (a resumed system does not run "at startup"
rem tasks and trips over hardware changes). Default: leave Windows' default on.
if /i "%FASTSTARTUP%"=="off" (
  powercfg /h off
  set HIBER=
  for /f "tokens=3" %%h in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\Power" /v HibernateEnabled ^| find "HibernateEnabled"') do set HIBER=%%h
  if "!HIBER!"=="0x0" (call "%~dp0beacon.cmd" faststartup ok "state=off") else call "%~dp0beacon.cmd" faststartup fail "state=!HIBER!" "msg=powercfg /h off did not take"
)

rem --- the every-boot probe: a "boot" beacon after each real boot or resume -----
call "%~dp0boot-probe.cmd"

rem --- the role's post script, then POST=<file> from the machine's cfg ---------
if defined ROLE_POST call "%ROLE_POST%"
if exist "%~dp0post.cmd" call "%~dp0post.cmd"

rem --- the verdict: this machine is deployed as asked --------------------------
call "%~dp0beacon.cmd" deployed ok "role=%ROLE%" "host=%COMPUTERNAME%"

rem --- reference machine: generalize and shut down, ready for MODE=capture -----
if /i "%REFERENCE%"=="yes" call "%~dp0prepare-capture.cmd"
