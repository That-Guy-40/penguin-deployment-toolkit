@echo off
rem 60-unattend - the Panther answer file, and C:\pdt\ on the installed disk:
rem id.cmd (SRV, ID, MAC + this run's token), beacon.cmd and firstlogon.cmd,
rem so the installed system continues this run's timeline.
setlocal EnableExtensions EnableDelayedExpansion
call X:\pdt\env.cmd
if not exist W:\Windows\Panther mkdir W:\Windows\Panther
%CURL% -f -o W:\Windows\Panther\unattend.xml "%SRV%/unattend/%UNATTEND%" || exit /b !errorlevel!
if not exist W:\pdt mkdir W:\pdt
copy /y %SystemRoot%\System32\id.cmd W:\pdt\id.cmd || exit /b !errorlevel!
>>W:\pdt\id.cmd echo set "RUN=%RUN%"
copy /y %PDT%\beacon.cmd W:\pdt\beacon.cmd || exit /b !errorlevel!
%CURL% -f -o W:\pdt\firstlogon.cmd "%SRV%/post/firstlogon.cmd" || exit /b !errorlevel!
rem POST=<file>: a script from http/post/ that firstlogon.cmd runs (as post.cmd).
if defined POST (%CURL% -f -o W:\pdt\post.cmd "%SRV%/post/%POST%" || exit /b !errorlevel!)
rem A reference machine generalizes itself after first logon (REFERENCE=yes).
if /i "%REFERENCE%"=="yes" (
  >>W:\pdt\id.cmd echo set "REFERENCE=yes"
  %CURL% -f -o W:\pdt\prepare-capture.cmd "%SRV%/post/prepare-capture.cmd" || exit /b !errorlevel!
)
rem Last step that touches the Windows partition: push DISM's log while it
rem still exists, then remove the scratch directory it lives in.
call %PDT%\push.cmd
if exist W:\Scratch rmdir /s /q W:\Scratch
exit /b 0
