@echo off
rem pushloop.cmd <token> - started in the background by step.cmd. Pushes the
rem logs every 20 s for as long as the step that started it is still running
rem (X:\pdt\step.running still holds its token), then ends.
:loop
ping -n 21 127.0.0.1 >nul
set CUR=
if exist X:\pdt\step.running set /p CUR=<X:\pdt\step.running
if not "%CUR%"=="%~1" exit /b 0
call X:\pdt\push.cmd
goto :loop
