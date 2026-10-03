@echo off
rem post.cmd for the lab-apps role: runs at first logon after the apps, as
rem the deploy account (elevated). %~dp0 is C:\pdt\role\. The lab checks that
rem a role's post script runs by this beacon and by the file it leaves behind.
call "%~dp0..\id.cmd"
> "%~dp0..\role-post.txt" echo lab-apps post.cmd ran %DATE% %TIME% on %COMPUTERNAME%
set SEVENZIP=no
if exist "%ProgramFiles%\7-Zip\7z.exe" set SEVENZIP=yes
call "%~dp0..\beacon.cmd" role-post ok "sevenzip=%SEVENZIP%"
