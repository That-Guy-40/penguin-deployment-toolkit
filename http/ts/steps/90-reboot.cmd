@echo off
rem 90-reboot - restart into the installed system. Delayed a few seconds so
rem the runner can still report this step, ts-done, and push the logs.
start "" /b cmd /c "ping -n 6 127.0.0.1 >nul & wpeutil reboot"
exit /b 0
