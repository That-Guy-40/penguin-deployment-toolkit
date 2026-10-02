@echo off
rem step.cmd <name> - run ONE step the way the sequence does: start beacon,
rem the step's output into the log, ok/fail beacon with its exit code, logs
rem pushed. To watch a step's output instead, run the step file directly:
rem   X:\pdt\steps\<name>.cmd
call X:\pdt\env.cmd
set STEP=%~1
if not exist %PDT%\steps\%STEP%.cmd echo [pdt] no such step: %STEP%& exit /b 1
echo [pdt] %STEP% ...
>>%LOG% echo.
>>%LOG% echo [pdt] ===== %STEP%
del %PDT%\step.msg 2>nul
call %PDT%\beacon.cmd %STEP% start
rem While the step runs, push the logs every 20 s, so a long step (a big
rem download, DISM adding updates) can be followed with bin/logs.
set PUSHTOKEN=%RANDOM%%RANDOM%
>%PDT%\step.running echo %PUSHTOKEN%
start "" /b cmd /c %PDT%\pushloop.cmd %PUSHTOKEN%
rem The step runs in a CHILD cmd, not with "call". In WinPE a pipe to a program
rem that does not exist ends batch processing altogether, callers included,
rem without a word (verified). In a child that costs only the step: we get
rem exit code 255 and can still say so.
cmd /c %PDT%\steps\%STEP%.cmd >>%LOG% 2>&1
set RC=%errorlevel%
del %PDT%\step.running 2>nul
rem A step may leave one line in step.msg: why it failed, or that it had nothing to do.
set STEP_MSG=
if exist %PDT%\step.msg set /p STEP_MSG=<%PDT%\step.msg
if "%RC%"=="255" if not defined STEP_MSG set STEP_MSG=the step was cut short: cmd aborted its batch file, see the log
if "%RC%"=="0" goto :step_ok
call %PDT%\beacon.cmd %STEP% fail "rc=%RC%" "msg=%STEP_MSG%"
call %PDT%\push.cmd
echo [pdt] step %STEP% FAILED (rc=%RC%). %STEP_MSG%
echo [pdt] log: %LOG%   re-run it visibly: %PDT%\steps\%STEP%.cmd
exit /b %RC%
:step_ok
if defined STEP_MSG (call %PDT%\beacon.cmd %STEP% ok "msg=%STEP_MSG%") else (call %PDT%\beacon.cmd %STEP% ok)
call %PDT%\push.cmd
exit /b 0
