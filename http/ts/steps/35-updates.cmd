@echo off
rem 35-updates - optional: add update packages (.msu/.cab) to the applied
rem image. UPDATES=<name> in a cfg names http/updates/<name>.wim, a pack made
rem by bin/pack-updates. This is where cumulative updates go, since they
rem cannot be integrated into the image on Linux.
setlocal EnableExtensions EnableDelayedExpansion
call X:\pdt\env.cmd
if not defined UPDATES (>%PDT%\step.msg echo skipped: no UPDATES set& exit /b 0)
%CURL% -f -o W:\updates.wim "%SRV%/updates/%UPDATES%.wim" || exit /b !errorlevel!
if not exist W:\Updates mkdir W:\Updates
dism /apply-image /imagefile:W:\updates.wim /index:1 /applydir:W:\Updates /scratchdir:W:\Scratch /logpath:%DISMLOG% || exit /b !errorlevel!
rem The pack may carry a target list and an expectation (bin/pack-updates
rem --target / --expect); keep them out of the folder DISM scans for packages.
del %PDT%\expect.txt %PDT%\targets.txt 2>nul
if exist W:\Updates\pdt-expect.txt move /y W:\Updates\pdt-expect.txt %PDT%\expect.txt
if exist W:\Updates\pdt-targets.txt move /y W:\Updates\pdt-targets.txt %PDT%\targets.txt
rem /loglevel:2 = errors and warnings only. At the default level this one
rem command wrote a 444 MB log.
rem With targets: install exactly those files; DISM takes whatever else they
rem need (a checkpoint cumulative update, say) from the same folder. Without:
rem every package in the folder, each in its own right.
set RC=0
if exist %PDT%\targets.txt (
  for /f "usebackq delims=" %%t in ("%PDT%\targets.txt") do (
    echo adding %%t
    dism /image:W:\ /add-package /packagepath:"W:\Updates\%%t" /scratchdir:W:\Scratch /logpath:%DISMLOG% /loglevel:2 || set RC=!errorlevel!
  )
) else (
  dism /image:W:\ /add-package /packagepath:W:\Updates /scratchdir:W:\Scratch /logpath:%DISMLOG% /loglevel:2 || set RC=!errorlevel!
)
rem DISM's exit code is not the outcome. Handed a folder holding a checkpoint
rem update and a newer cumulative update, the 26100.1 WinPE DISM fails on the
rem checkpoint as a package of its own (0x80070228, exit 552), installs the
rem cumulative update anyway, and exits 552 (verified: the deployed system then
rem reported the updated build). So when the pack says which package version to
rem expect, the verdict is whether the image now lists it as installed.
set EXPECT=
if exist %PDT%\expect.txt set /p EXPECT=<%PDT%\expect.txt
if not defined EXPECT goto :cleanup
dism /image:W:\ /get-packages /format:table /scratchdir:W:\Scratch /logpath:%DISMLOG% /loglevel:2 >%PDT%\packages.txt
rem Lines naming the expected package, then: is its state Installed or
rem Install Pending? (find is case-sensitive, so "Uninstall Pending" is no match.)
rem No findstr in WinPE, and no pipes: see step.cmd.
find "!EXPECT!" %PDT%\packages.txt >%PDT%\expect-match.txt
type %PDT%\expect-match.txt
find "Install" %PDT%\expect-match.txt >nul
if errorlevel 1 goto :not_installed
if not "!RC!"=="0" >%PDT%\step.msg echo dism exit !RC!, but package !EXPECT! is installed in the image
set RC=0
goto :cleanup
:not_installed
>%PDT%\step.msg echo expected package !EXPECT! is not installed in the image (dism exit !RC!)
if "!RC!"=="0" set RC=1
:cleanup
rmdir /s /q W:\Updates
del W:\updates.wim
exit /b %RC%
