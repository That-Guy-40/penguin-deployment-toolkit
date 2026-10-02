@echo off
rem 20-disk - WIPE disk 0 and partition it (ts/diskpart/<DISKPART>):
rem S: EFI system, MSR, W: Windows, R: recovery.
setlocal EnableExtensions EnableDelayedExpansion
call X:\pdt\env.cmd
%CURL% -f -o %PDT%\diskpart.txt "%SRV%/ts/diskpart/%DISKPART%" || exit /b !errorlevel!
diskpart /s %PDT%\diskpart.txt || exit /b !errorlevel!
if not exist W:\ (>%PDT%\step.msg echo the diskpart script did not produce W:& exit /b 1)
if not exist W:\Scratch mkdir W:\Scratch || exit /b !errorlevel!
exit /b 0
