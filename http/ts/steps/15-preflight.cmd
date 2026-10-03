@echo off
rem 15-preflight - before anything is destroyed: is every file this install
rem needs on the server? A typo in a cfg must cost a reboot, not a disk.
setlocal EnableExtensions EnableDelayedExpansion
call X:\pdt\env.cmd
set MISSING=
for %%u in ("ts/diskpart/%DISKPART%" "images/%IMAGE%" "unattend/%UNATTEND%" "ts/beacon.cmd" "post/firstlogon.cmd" "post/boot-probe.cmd") do (
  %CURL% -f -I -o nul "%SRV%/%%~u" || set "MISSING=!MISSING! %%~u"
)
if defined DRIVERS (%CURL% -f -I -o nul "%SRV%/drivers/%DRIVERS%.wim" || set "MISSING=!MISSING! drivers/%DRIVERS%.wim")
if /i "%REFERENCE%"=="yes" (%CURL% -f -I -o nul "%SRV%/post/prepare-capture.cmd" || set "MISSING=!MISSING! post/prepare-capture.cmd")
if defined POST (%CURL% -f -I -o nul "%SRV%/post/%POST%" || set "MISSING=!MISSING! post/%POST%")
rem A role is a directory roles/<ROLE>/ with a role.cfg naming its files.
if defined ROLE (
  %CURL% -f -o %PDT%\role.cfg "%SRV%/roles/%ROLE%/role.cfg" || set "MISSING=!MISSING! roles/%ROLE%/role.cfg"
  if exist %PDT%\role.cfg for /f "usebackq eol=# tokens=1,* delims==" %%a in ("%PDT%\role.cfg") do (
    for %%k in (UNATTEND APPS POST USERS SKEL) do if /i "%%a"=="%%k" (%CURL% -f -I -o nul "%SRV%/roles/%ROLE%/%%b" || set "MISSING=!MISSING! roles/%ROLE%/%%b")
    rem SKEL names a manifest; every file it lists must be there too.
    if /i "%%a"=="SKEL" (
      %CURL% -f -o %PDT%\skel.txt "%SRV%/roles/%ROLE%/%%b" && for /f "usebackq eol=# delims=" %%l in ("%PDT%\skel.txt") do (
        %CURL% -f -I -o nul "%SRV%/roles/%ROLE%/skel/%%l" || set "MISSING=!MISSING! roles/%ROLE%/skel/%%l"
      )
    )
    if /i "%%a"=="USERS" (%CURL% -f -I -o nul "%SRV%/post/users.ps1" || set "MISSING=!MISSING! post/users.ps1")
    if /i "%%a"=="FILES" for %%f in (%%b) do (%CURL% -f -I -o nul "%SRV%/roles/%ROLE%/%%f" || set "MISSING=!MISSING! roles/%ROLE%/%%f")
    if /i "%%a"=="APPS" (%CURL% -f -I -o nul "%SRV%/post/winget/files.txt" || set "MISSING=!MISSING! post/winget/files.txt (run bin/fetch-tools winget)")
  )
  if exist %PDT%\role.cfg (%CURL% -f -I -o nul "%SRV%/post/winget.cmd" || set "MISSING=!MISSING! post/winget.cmd")
)
if defined UPDATES (%CURL% -f -I -o nul "%SRV%/updates/%UPDATES%.wim" || set "MISSING=!MISSING! updates/%UPDATES%.wim")
if not defined MISSING exit /b 0
echo not on the server:!MISSING!
>%PDT%\step.msg echo missing:!MISSING!
exit /b 1
