@echo off
rem 25-download - fetch the OS image over HTTP onto the new Windows partition.
setlocal EnableExtensions EnableDelayedExpansion
call X:\pdt\env.cmd
%CURL% -f --retry 2 -o W:\image.wim "%SRV%/images/%IMAGE%" || exit /b !errorlevel!
exit /b 0
