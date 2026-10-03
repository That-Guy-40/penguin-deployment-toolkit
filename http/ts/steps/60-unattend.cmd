@echo off
rem 60-unattend - the Panther answer file, and C:\pdt\ on the installed disk:
rem id.cmd (SRV, ID, MAC + this run's token), beacon.cmd and firstlogon.cmd,
rem so the installed system continues this run's timeline.
setlocal EnableExtensions EnableDelayedExpansion
call X:\pdt\env.cmd
if not exist W:\Windows\Panther mkdir W:\Windows\Panther
rem The role may bring its own unattend file; otherwise the cfg's UNATTEND.
set UNATTEND_URL=%SRV%/unattend/%UNATTEND%
set ROLE_UNATTEND=
if defined ROLE (
  %CURL% -f -o %PDT%\role.cfg "%SRV%/roles/%ROLE%/role.cfg" || exit /b !errorlevel!
  for /f "usebackq eol=# tokens=1,* delims==" %%a in ("%PDT%\role.cfg") do if /i "%%a"=="UNATTEND" set "ROLE_UNATTEND=%%b"
)
if defined ROLE_UNATTEND set UNATTEND_URL=%SRV%/roles/%ROLE%/%ROLE_UNATTEND%
%CURL% -f -o W:\Windows\Panther\unattend.xml "%UNATTEND_URL%" || exit /b !errorlevel!
rem Start C:\pdt afresh: an image captured from a reference machine carries
rem that machine's role files and scripts, which must not run again here.
if exist W:\pdt rmdir /s /q W:\pdt
mkdir W:\pdt || exit /b !errorlevel!
copy /y %SystemRoot%\System32\id.cmd W:\pdt\id.cmd || exit /b !errorlevel!
>>W:\pdt\id.cmd echo set "RUN=%RUN%"
copy /y %PDT%\beacon.cmd W:\pdt\beacon.cmd || exit /b !errorlevel!
%CURL% -f -o W:\pdt\firstlogon.cmd "%SRV%/post/firstlogon.cmd" || exit /b !errorlevel!
%CURL% -f -o W:\pdt\boot-probe.cmd "%SRV%/post/boot-probe.cmd" || exit /b !errorlevel!
rem The role's files for first logon: role.cfg and whatever it names.
if defined ROLE (
  >>W:\pdt\id.cmd echo set "ROLE=%ROLE%"
  mkdir W:\pdt\role
  copy /y %PDT%\role.cfg W:\pdt\role\role.cfg >nul || exit /b !errorlevel!
  for /f "usebackq eol=# tokens=1,* delims==" %%a in ("%PDT%\role.cfg") do (
    for %%k in (APPS POST) do if /i "%%a"=="%%k" (%CURL% -f -o "W:\pdt\role\%%b" "%SRV%/roles/%ROLE%/%%b" || exit /b !errorlevel!)
  )
  %CURL% -f -o W:\pdt\winget.cmd "%SRV%/post/winget.cmd" || exit /b !errorlevel!
)
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
