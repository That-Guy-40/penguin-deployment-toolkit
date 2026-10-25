@echo off
rem 50-boot - write the boot files to the EFI system partition and the firmware boot entry.
setlocal EnableExtensions EnableDelayedExpansion
call X:\pdt\env.cmd
bcdboot W:\Windows /s S: /f UEFI || exit /b !errorlevel!
rem bcdboot also writes the firmware's own boot entry for Windows and puts it
rem first (its default; /addlast is the alternative). Record the firmware's
rem order as it stands now, and say in the beacon whether Windows leads it: a
rem machine whose firmware boots something else first (the network, a blank
rem disk 0 when DISK=1) comes back here after 90-reboot and, with MODE=deploy
rem still set, re-images itself (bin/netboot <m> local is the way out).
bcdedit /enum firmware >%PDT%\firmware.txt 2>&1
type %PDT%\firmware.txt
set FIRST=
for /f "tokens=1,2" %%a in ('find "displayorder" %PDT%\firmware.txt') do if /i "%%a"=="displayorder" if not defined FIRST set "FIRST=%%b"
if not defined FIRST (>%PDT%\step.msg echo boot files written; the firmware boot order could not be read ^(bcdedit /enum firmware^)& exit /b 0)
if /i "!FIRST!"=="{bootmgr}" (>%PDT%\step.msg echo boot files written; the firmware boots Windows Boot Manager first) else (>%PDT%\step.msg echo boot files written; the firmware boots !FIRST! first, NOT Windows Boot Manager: fix its boot order, or bin/netboot this machine local, or it re-images itself)
exit /b 0
