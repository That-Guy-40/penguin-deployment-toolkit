@echo off
rem push.cmd - upload this run's logs (best effort): PUT /uploads/<id>/<run>/
call X:\pdt\env.cmd
%CURL% -T %LOG% "%SRV%/uploads/%ID%/%RUN%/ts.log" -o nul --max-time 60 >nul 2>&1
if exist %DISMLOG% %CURL% -T %DISMLOG% "%SRV%/uploads/%ID%/%RUN%/dism.log" -o nul --max-time 300 >nul 2>&1
exit /b 0
