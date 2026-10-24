@echo off
rem 17-diskguard - decide which disk 20-disk may wipe, before anything is
rem destroyed. disks.js (WMI) lists the disks and keeps the fixed, non-USB
rem ones of at least MINDISK_GB GiB; DISK=<n> from the machine or model cfg
rem names one of them, or with no DISK= there must be exactly one. Anything
rem else fails this step, and 20-disk refuses to run without the choice
rem (X:\pdt\disk.txt). The listing is in the log.
setlocal EnableExtensions EnableDelayedExpansion
call X:\pdt\env.cmd
del %PDT%\disk.txt 2>nul
if not defined MINDISK_GB set MINDISK_GB=32
set WANT=-
if defined DISK set WANT=%DISK%
cscript //nologo %PDT%\disks.js %MINDISK_GB% %WANT% %PDT%\disk.txt %PDT%\step.msg
set RC=%errorlevel%
if not "%RC%"=="0" (
  if not exist %PDT%\step.msg >%PDT%\step.msg echo disks.js failed with rc=%RC%, is WMI in this WinPE?
  del %PDT%\disk.txt 2>nul
  exit /b 1
)
if not exist %PDT%\disk.txt (>%PDT%\step.msg echo disks.js chose no disk& exit /b 1)
exit /b 0
