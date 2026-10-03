@echo off
rem boot-probe.cmd - "this machine started": one beacon per boot, for ever.
rem   boot-probe.cmd            register the two scheduled tasks (firstlogon.cmd)
rem   boot-probe.cmd <trigger>  what the tasks run: beacon "boot ok trigger=..."
rem Two triggers because one is not enough (verified 2026-10-02): "at system
rem startup" fires after a real boot or restart but NOT when Windows resumes
rem from a fast-startup shutdown; System event Kernel-Boot 27 is logged in
rem both cases. After a real boot both fire, so expect up to two events.
setlocal EnableExtensions
call "%~dp0id.cmd"
if not "%~1"=="" (
  call "%~dp0beacon.cmd" boot ok "trigger=%~1" "host=%COMPUTERNAME%"
  exit /b 0
)
set OUT=%~dp0boot-probe.txt
schtasks /create /f /sc onstart /ru SYSTEM /rl highest /tn PDT-boot-onstart /tr "%~f0 onstart" > "%OUT%" 2>&1
set RC1=%errorlevel%
schtasks /create /f /sc onevent /ec System /mo "*[System[Provider[@Name='Microsoft-Windows-Kernel-Boot'] and EventID=27]]" /ru SYSTEM /rl highest /tn PDT-boot-event /tr "%~f0 event" >> "%OUT%" 2>&1
set RC2=%errorlevel%
set V=ok
if not "%RC1%"=="0" set V=fail
if not "%RC2%"=="0" set V=fail
call "%~dp0beacon.cmd" boot-tasks %V% "onstart_rc=%RC1%" "event_rc=%RC2%"
curl.exe -sS -T "%OUT%" "%SRV%/uploads/%ID%/%RUN%/boot-probe.txt" -o nul --max-time 60
exit /b 0
