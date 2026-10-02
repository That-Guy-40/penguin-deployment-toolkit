@echo off
rem 15-preflight - before anything is destroyed: is every file this install
rem needs on the server? A typo in a cfg must cost a reboot, not a disk.
setlocal EnableExtensions EnableDelayedExpansion
call X:\pdt\env.cmd
set MISSING=
for %%u in ("ts/diskpart/%DISKPART%" "images/%IMAGE%" "unattend/%UNATTEND%" "ts/beacon.cmd" "post/firstlogon.cmd") do (
  %CURL% -f -I -o nul "%SRV%/%%~u" || set "MISSING=!MISSING! %%~u"
)
if defined DRIVERS (%CURL% -f -I -o nul "%SRV%/drivers/%DRIVERS%.wim" || set "MISSING=!MISSING! drivers/%DRIVERS%.wim")
if /i "%REFERENCE%"=="yes" (%CURL% -f -I -o nul "%SRV%/post/prepare-capture.cmd" || set "MISSING=!MISSING! post/prepare-capture.cmd")
if defined POST (%CURL% -f -I -o nul "%SRV%/post/%POST%" || set "MISSING=!MISSING! post/%POST%")
if defined UPDATES (%CURL% -f -I -o nul "%SRV%/updates/%UPDATES%.wim" || set "MISSING=!MISSING! updates/%UPDATES%.wim")
if not defined MISSING exit /b 0
echo not on the server:!MISSING!
>%PDT%\step.msg echo missing:!MISSING!
exit /b 1
