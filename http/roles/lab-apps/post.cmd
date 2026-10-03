@echo off
rem post.cmd for the lab-apps role: runs at first logon after apps and users,
rem as the deploy account (elevated). %~dp0 is C:\pdt\role\. It is the lab's
rem probe of the role: 7-Zip present; the accounts from users.txt usable with
rem the generated passwords (still in ..\users-out.txt at this point: it is
rem removed at the end of first logon); alice's fresh profile carrying the
rem skel; and the deploy account taking its generated password (not blank).
setlocal EnableExtensions
call "%~dp0..\id.cmd"
> "%~dp0..\role-post.txt" echo lab-apps post.cmd ran %DATE% %TIME% on %COMPUTERNAME%
set SEVENZIP=no
if exist "%ProgramFiles%\7-Zip\7z.exe" set SEVENZIP=yes
set ALICE_LOGON=untested
set ALICE_SKEL=untested
set DEPLOY_LOGON=untested
if exist "%~dp0..\users-out.txt" (
  for /f "delims=" %%r in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0probe-users.ps1" "%~dp0..\users-out.txt"') do set "%%r"
)
call "%~dp0..\beacon.cmd" role-post ok "sevenzip=%SEVENZIP%" "alice_logon=%ALICE_LOGON%" "alice_skel=%ALICE_SKEL%" "deploy_logon=%DEPLOY_LOGON%"
