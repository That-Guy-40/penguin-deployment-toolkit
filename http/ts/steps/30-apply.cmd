@echo off
rem 30-apply - apply the image to W:\ with DISM, then drop the downloaded file.
setlocal EnableExtensions EnableDelayedExpansion
call X:\pdt\env.cmd
rem Only an image 25-download verified in THIS boot (X: is the RAM disk) may be applied:
rem a resumed "deploy 30" after a failed or interrupted download finds no token and stops.
if not exist %PDT%\image.verified (>%PDT%\step.msg echo W:\image.wim was not verified by 25-download in this boot: run deploy 25& exit /b 1)
dism /apply-image /imagefile:W:\image.wim /index:1 /applydir:W:\ /scratchdir:W:\Scratch /logpath:%DISMLOG% || exit /b !errorlevel!
del W:\image.wim
exit /b 0
