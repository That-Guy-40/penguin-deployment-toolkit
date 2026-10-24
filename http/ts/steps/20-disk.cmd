@echo off
rem 20-disk - WIPE the disk 17-diskguard chose and partition it
rem (ts/diskpart/<DISKPART>): S: EFI system, MSR, W: Windows, R: recovery.
rem The script names its disk as @DISK@; the number comes from X:\pdt\disk.txt,
rem written by 17-diskguard, and never from anywhere else.
setlocal EnableExtensions EnableDelayedExpansion
call X:\pdt\env.cmd
if not exist %PDT%\disk.txt (>%PDT%\step.msg echo no disk chosen: 17-diskguard has not run& exit /b 1)
set DISKN=
set /p DISKN=<%PDT%\disk.txt
if not defined DISKN (>%PDT%\step.msg echo X:\pdt\disk.txt is empty& exit /b 1)
%CURL% -f -o %PDT%\diskpart.tpl "%SRV%/ts/diskpart/%DISKPART%" || exit /b !errorlevel!
type %PDT%\diskpart.tpl | find "@DISK@" >nul || (>%PDT%\step.msg echo ts/diskpart/%DISKPART% has no @DISK@ token& exit /b 1)
(for /f "usebackq eol=~ delims=" %%l in ("%PDT%\diskpart.tpl") do (
  set "L=%%l"
  echo !L:@DISK@=%DISKN%!
)) >%PDT%\diskpart.txt
echo [pdt] disk %DISKN%: wiping and partitioning
diskpart /s %PDT%\diskpart.txt || exit /b !errorlevel!
if not exist W:\ (>%PDT%\step.msg echo the diskpart script did not produce W:& exit /b 1)
if not exist W:\Scratch mkdir W:\Scratch || exit /b !errorlevel!
exit /b 0
