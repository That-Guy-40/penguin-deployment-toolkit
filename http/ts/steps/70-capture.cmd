@echo off
rem 70-capture - MODE=capture: capture the installed Windows volume to a WIM
rem and upload it. Nothing is wiped. The WIM is written to <volume>\pdt\ on
rem the volume being captured (\pdt is excluded from the image, which also
rem keeps the reference machine's own identity out of it), so the volume needs
rem that much free space.
rem Shut the reference machine down FULLY first (sysprep /shutdown, or
rem shutdown /s /t 0): a hibernated (fast startup) volume is not consistent.
setlocal EnableExtensions EnableDelayedExpansion
call X:\pdt\env.cmd
set VOL=
for %%d in (C D E F G H I W) do if not defined VOL if exist %%d:\Windows\System32\config\SYSTEM set VOL=%%d:
if not defined VOL (>%PDT%\step.msg echo no installed Windows volume found& exit /b 1)
if exist %VOL%\hiberfil.sys echo note: %VOL%\hiberfil.sys exists - was this machine shut down fully?
rem Is this a generalized (sysprep) installation, i.e. a role image, or one
rem particular machine? Read its setup state from the offline registry. (The
rem machine cannot tell us itself: generalizing removes its network adapter,
rem so prepare-capture's last beacon never arrives.)
set STATE=unknown
reg load HKLM\PDTSW %VOL%\Windows\System32\config\SOFTWARE
for /f "tokens=2,*" %%a in ('reg query "HKLM\PDTSW\Microsoft\Windows\CurrentVersion\Setup\State" /v ImageState 2^>nul ^| find "ImageState"') do set STATE=%%b
reg unload HKLM\PDTSW
echo image state of %VOL% : !STATE!
%CURL% -f -o %PDT%\capture.ini "%SRV%/ts/capture.ini" || exit /b !errorlevel!
if not exist %VOL%\pdt\scratch mkdir %VOL%\pdt\scratch || exit /b !errorlevel!
del %VOL%\pdt\capture.wim 2>nul
dism /capture-image /imagefile:%VOL%\pdt\capture.wim /capturedir:%VOL%\ /name:"captured %ID%" /configfile:%PDT%\capture.ini /checkintegrity /scratchdir:%VOL%\pdt\scratch /logpath:%DISMLOG% || exit /b !errorlevel!
for %%f in (%VOL%\pdt\capture.wim) do set SIZE=%%~zf
echo captured %VOL% : !SIZE! bytes, uploading
%CURL% -f -T %VOL%\pdt\capture.wim "%SRV%/uploads/%ID%/%RUN%/capture.wim" -o nul || exit /b !errorlevel!
del %VOL%\pdt\capture.wim
rmdir /s /q %VOL%\pdt\scratch
>%PDT%\step.msg echo uploaded capture.wim !SIZE! bytes from %VOL%, state !STATE!
exit /b 0
