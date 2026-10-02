@echo off
rem 45-winre - put the Windows Recovery Environment on the recovery partition
rem (R:) and register it with the applied Windows. Required, not optional:
rem without it "Reset this PC" and automatic repair have nothing to boot.
setlocal EnableExtensions EnableDelayedExpansion
call X:\pdt\env.cmd
if not exist R:\ (>%PDT%\step.msg echo no recovery partition R: - check ts/diskpart/%DISKPART%& exit /b 1)
if not exist R:\Recovery\WindowsRE mkdir R:\Recovery\WindowsRE || exit /b !errorlevel!
rem A base image carries Winre.wim. An image captured from an installed
rem machine does not (Windows keeps it on that machine's recovery partition),
rem so the server keeps one beside every image: images/<name>.winre.wim.
if exist W:\Windows\System32\Recovery\Winre.wim (
  xcopy /h /y W:\Windows\System32\Recovery\Winre.wim R:\Recovery\WindowsRE\ || exit /b !errorlevel!
) else (
  echo the image has no Winre.wim, fetching images/%IMAGE:.wim=%.winre.wim
  %CURL% -f -o R:\Recovery\WindowsRE\Winre.wim "%SRV%/images/%IMAGE:.wim=%.winre.wim"
  if errorlevel 1 (>%PDT%\step.msg echo no Winre.wim in the image and none on the server at images/%IMAGE:.wim=%.winre.wim& exit /b 1)
  >%PDT%\step.msg echo Winre.wim taken from the server: the image has none
)
W:\Windows\System32\Reagentc.exe /Setreimage /Path R:\Recovery\WindowsRE /Target W:\Windows || exit /b !errorlevel!
W:\Windows\System32\Reagentc.exe /Info /Target W:\Windows
exit /b 0
