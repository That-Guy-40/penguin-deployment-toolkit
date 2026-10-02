@echo off
rem 30-apply - apply the image to W:\ with DISM, then drop the downloaded file.
setlocal EnableExtensions EnableDelayedExpansion
call X:\pdt\env.cmd
dism /apply-image /imagefile:W:\image.wim /index:1 /applydir:W:\ /scratchdir:W:\Scratch /logpath:%DISMLOG% || exit /b !errorlevel!
del W:\image.wim
exit /b 0
