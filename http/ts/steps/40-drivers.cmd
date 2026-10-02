@echo off
rem 40-drivers - optional: inject a driver pack into the applied image.
rem DRIVERS=<name> (usually from models/<slug>.cfg) names
rem http/drivers/<name>.wim, made by bin/pack-drivers.
setlocal EnableExtensions EnableDelayedExpansion
call X:\pdt\env.cmd
if not defined DRIVERS (>%PDT%\step.msg echo skipped: no DRIVERS set& exit /b 0)
%CURL% -f -o W:\drivers.wim "%SRV%/drivers/%DRIVERS%.wim" || exit /b !errorlevel!
if not exist W:\Drivers mkdir W:\Drivers
dism /apply-image /imagefile:W:\drivers.wim /index:1 /applydir:W:\Drivers /scratchdir:W:\Scratch /logpath:%DISMLOG% || exit /b !errorlevel!
dism /image:W:\ /add-driver /driver:W:\Drivers /recurse /scratchdir:W:\Scratch /logpath:%DISMLOG%
set RC=!errorlevel!
rmdir /s /q W:\Drivers
del W:\drivers.wim
exit /b %RC%
