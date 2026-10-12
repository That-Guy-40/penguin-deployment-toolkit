@echo off
rem remove-deploy.cmd - delete the toolkit's own account ("deploy", made by
rem the unattend to run first logon) once it is no longer needed.
rem   remove-deploy.cmd        (firstlogon.cmd, role DEPLOY=remove): delete the
rem                            ACCOUNT now, while deploy is still logged on
rem                            (Windows allows it; the session lives on until
rem                            the restart that follows), register a one-shot
rem                            SYSTEM task for the next boot, restart
rem   remove-deploy.cmd run    (the task, as SYSTEM, at the next boot): delete
rem                            the PROFILE (cannot go while loaded), check,
rem                            beacon, unregister
rem Why in that order: a task that deleted the account at the next boot raced
rem the sign-in screen, which had already listed deploy (verified: the tile
rem stayed until the boot after). Deleted before the restart, the next
rem sign-in screen never sees it.
rem The role must give another Administrators account in USERS (lint checks),
rem or nobody could log on afterwards.
setlocal EnableExtensions
call "%~dp0id.cmd"
if /i "%~1"=="run" goto :run
set OUT=%~dp0remove-deploy.txt
> "%OUT%" echo remove-deploy (first logon) %DATE% %TIME%
net user deploy /delete >> "%OUT%" 2>&1
set ACCT=deleted
net user deploy >nul 2>&1 && set ACCT=still-there
rem What the sign-in screen and Winlogon remember of the account.
set LUI=HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI
for %%v in (LastLoggedOnUser LastLoggedOnSAMUser LastLoggedOnDisplayName LastLoggedOnUserSID LastLoggedOnProvider SelectedUserSID) do reg delete "%LUI%" /v %%v /f >nul 2>&1
reg delete "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultUserName /f >nul 2>&1
schtasks /create /f /sc onstart /ru SYSTEM /rl highest /tn PDT-remove-deploy /tr "%~f0 run" >> "%OUT%" 2>&1 && (
  call "%~dp0beacon.cmd" deploy-remove ok "account=%ACCT%" "msg=profile removal scheduled for the next boot; restarting"
) || call "%~dp0beacon.cmd" deploy-remove fail "account=%ACCT%" "msg=could not register the profile-removal task"
exit /b 0

:run
set OUT=%~dp0remove-deploy.txt
>> "%OUT%" echo remove-deploy (next boot) %DATE% %TIME%
rem The profile (Win32_UserProfile removal also cleans ProfileList); the
rem account is already gone, so this is an orphaned SID's profile.
powershell -NoProfile -Command "Get-CimInstance Win32_UserProfile | Where-Object { $_.LocalPath -like '*\deploy' } | Remove-CimInstance" >> "%OUT%" 2>&1
if exist "%SystemDrive%\Users\deploy" rmdir /s /q "%SystemDrive%\Users\deploy" >> "%OUT%" 2>&1
set V=ok
net user deploy >nul 2>&1 && set V=fail
if exist "%SystemDrive%\Users\deploy" set V=fail
>> "%OUT%" echo === accounts after
net user >> "%OUT%" 2>&1
call "%~dp0beacon.cmd" deploy-removed %V% "profile_gone=%V%"
curl.exe -sS -T "%OUT%" "%SRV%/uploads/%ID%/%RUN%/remove-deploy.txt" -o nul --max-time 60
schtasks /delete /f /tn PDT-remove-deploy >nul 2>&1
exit /b 0
