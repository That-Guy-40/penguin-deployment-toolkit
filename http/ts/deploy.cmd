@echo off
rem deploy.cmd - bootstrap + runner of the WinPE task sequence.
rem Injected into X:\Windows\System32 by wimboot, started by winpeshl.ini.
rem
rem   deploy          run the sequence for this machine's MODE from the top
rem   deploy 40       resume: run it from step 40 on (STOP_BEFORE/STOP_AFTER
rem                   are ignored, because now a person is driving)
rem
rem It fetches everything else from the server on every run (env.cmd, the
rem helpers, ts/<MODE>.seq and the steps it lists), so editing a step on the
rem server and typing "deploy NN" re-runs it without a reboot.
rem
rem No setlocal anywhere in this file: when it ends, for whatever reason, the
rem prompt is left with the whole environment loaded (SRV, ID, RUN, MODE ...).
rem A disk is wiped ONLY by the steps of ts/deploy.seq, which run only when
rem machines/<id>.cfg on the server says MODE=deploy.

set PDT=X:\pdt
if not exist %PDT%\steps mkdir %PDT%\steps
set LOG=%PDT%\ts.log
set FROM=%~1

call %SystemRoot%\System32\id.cmd
if not defined SRV echo [pdt] id.cmd is missing or empty: this boot did not come through boot.ipxe.& exit /b 1

rem ------------------------------------------------------------------ network
if defined PDT_NET_UP goto :net_ok
echo [pdt] id %ID%  server %SRV%
rem Drivers WinPE lacks for this hardware were injected next to this file by
rem boot.ipxe (winpe-drivers/<chip>.ipxe) and are listed in pdt-drvload.txt.
if exist %SystemRoot%\System32\pdt-drvload.txt for /f "usebackq" %%i in ("%SystemRoot%\System32\pdt-drvload.txt") do (
  echo [pdt] drvload %%i
  drvload %SystemRoot%\System32\%%i >>%LOG% 2>&1
)
echo [pdt] starting the network (wpeinit)...
wpeinit >>%LOG% 2>&1
set /a TRIES=0
:waitnet
curl.exe -sS -f -o nul --max-time 3 "%SRV%/health" >nul 2>&1 && goto :net_up
set /a TRIES+=1
if %TRIES% geq 60 echo [pdt] the server %SRV% did not answer for two minutes.& ipconfig >>%LOG% 2>&1 & exit /b 1
ping -n 2 127.0.0.1 >nul
goto :waitnet
:net_up
set PDT_NET_UP=1
:net_ok

rem ------------------------------------------------------------------ toolkit
for %%f in (env.cmd step.cmd beacon.cmd push.cmd pushloop.cmd slug.js) do (
  curl.exe -sS -f -o %PDT%\%%f "%SRV%/ts/%%f" >>%LOG% 2>&1 || (echo [pdt] cannot fetch ts/%%f from the server.& exit /b 1)
)
rem One run token per boot; a resumed run continues the same run.
if not exist %PDT%\run.cmd >%PDT%\run.cmd echo set "RUN=%RANDOM%%RANDOM%"

rem ----------------------------------------------------------------- identify
rem Model defaults first (models/<slug of the product name>.cfg), then this
rem machine's own cfg (machines/<id>.cfg). env.cmd applies them in that order;
rem only the machine cfg can set MODE.
del %PDT%\machine.cfg %PDT%\model.cfg %PDT%\model.cmd 2>nul
for /f %%s in ('cscript //nologo %PDT%\slug.js 2^>nul') do >%PDT%\model.cmd echo set "MODEL=%%s"
if exist %PDT%\model.cmd call %PDT%\model.cmd
if defined MODEL curl.exe -sS -f -o %PDT%\model.cfg "%SRV%/models/%MODEL%.cfg" >>%LOG% 2>&1
curl.exe -sS -f -o %PDT%\machine.cfg "%SRV%/machines/%ID%.cfg" >>%LOG% 2>&1
if not exist %PDT%\machine.cfg echo [pdt] no machines/%ID%.cfg on the server: this machine is not listed.
call %PDT%\env.cmd
echo [pdt] run %RUN%  mode %MODE%  model "%MODEL%"
>>%LOG% echo [pdt] id %ID% run %RUN% mode %MODE% model %MODEL% from "%FROM%"
if not defined FROM call %PDT%\beacon.cmd ts-start ok "mode=%MODE%" "product=%PRODUCT%" "model=%MODEL%" "mac=%MAC%"

if /i "%MODE%"=="shell" goto :mode_shell

rem ----------------------------------------------------------------- sequence
curl.exe -sS -f -o %PDT%\sequence.seq "%SRV%/ts/%MODE%.seq" >>%LOG% 2>&1 || goto :no_sequence
for /f "usebackq eol=# tokens=1" %%s in ("%PDT%\sequence.seq") do (
  curl.exe -sS -f -o %PDT%\steps\%%s.cmd "%SRV%/ts/steps/%%s.cmd" >>%LOG% 2>&1 || (echo [pdt] cannot fetch ts/steps/%%s.cmd& call %PDT%\beacon.cmd sequence fail "msg=cannot fetch steps/%%s.cmd"& exit /b 1)
)
for /f "usebackq eol=# tokens=1" %%s in ("%PDT%\sequence.seq") do (
  call :one %%s || goto :ended
)
call %PDT%\beacon.cmd ts-done ok
call %PDT%\push.cmd
echo [pdt] sequence "%MODE%" finished.
exit /b 0

:ended
rem :one returned 1 (a step failed) or 2 (stopped on request); both leave the prompt.
exit /b 1

:mode_shell
call %PDT%\beacon.cmd shell ok "mode=%MODE%"
call %PDT%\push.cmd
echo [pdt] MODE=shell: nothing will be changed on this machine.
exit /b 0

:no_sequence
echo [pdt] the server has no ts/%MODE%.seq
call %PDT%\beacon.cmd sequence fail "msg=no ts/%MODE%.seq"
call %PDT%\push.cmd
exit /b 1

rem :one <step>   run one step of the sequence, honouring FROM and STOP_*.
rem               returns 0 = carry on, 1 = the step failed, 2 = stopped.
:one
set STEP=%~1
if defined FROM if "%STEP%" lss "%FROM%" exit /b 0
for /f "tokens=1 delims=-" %%n in ("%STEP%") do set STEPNO=%%n
if defined FROM goto :one_run
if defined STOP_BEFORE if /i "%STOP_BEFORE%"=="%STEP%" goto :one_stop_before
if defined STOP_BEFORE if "%STOP_BEFORE%"=="%STEPNO%" goto :one_stop_before
:one_run
call %PDT%\step.cmd %STEP% || exit /b 1
if defined FROM exit /b 0
if defined STOP_AFTER if /i "%STOP_AFTER%"=="%STEP%" goto :one_stop_after
if defined STOP_AFTER if "%STOP_AFTER%"=="%STEPNO%" goto :one_stop_after
exit /b 0
:one_stop_before
call %PDT%\beacon.cmd stop ok "before=%STEP%"
call %PDT%\push.cmd
echo [pdt] STOP_BEFORE=%STOP_BEFORE%: stopped before %STEP%. Try it by hand: %PDT%\steps\%STEP%.cmd
echo [pdt] then carry on with:  deploy %STEPNO%
exit /b 2
:one_stop_after
call %PDT%\beacon.cmd stop ok "after=%STEP%"
call %PDT%\push.cmd
echo [pdt] STOP_AFTER=%STOP_AFTER%: stopped after %STEP%.
exit /b 2
