@echo off
rem boot-probe.cmd - POST script for the 2026-10-02 spikes: which scheduled
rem task reliably reports "this machine started"?
rem   PDT-boot-onstart : trigger "at system startup"
rem   PDT-boot-event   : trigger on System event Kernel-Boot 27 ("the boot type
rem                      was ..."), which is also logged when Windows resumes
rem                      from a fast-startup (hybrid) shutdown
rem Then it restarts the machine once, so the first test needs no typing.
setlocal EnableExtensions
call "%~dp0id.cmd"
set OUT=%~dp0boot-probe.txt
schtasks /create /f /sc onstart /ru SYSTEM /rl highest /tn PDT-boot-onstart /tr "cmd /c C:\pdt\beacon.cmd boot-onstart ok" > "%OUT%" 2>&1
set RC1=%errorlevel%
schtasks /create /f /sc onevent /ec System /mo "*[System[Provider[@Name='Microsoft-Windows-Kernel-Boot'] and EventID=27]]" /ru SYSTEM /rl highest /tn PDT-boot-event /tr "cmd /c C:\pdt\beacon.cmd boot-event ok" >> "%OUT%" 2>&1
set RC2=%errorlevel%
call "%~dp0beacon.cmd" boot-tasks ok "onstart_rc=%RC1%" "event_rc=%RC2%"
curl.exe -sS -T "%OUT%" "%SRV%/uploads/%ID%/%RUN%/boot-probe.txt" -o nul --max-time 60
shutdown /r /t 15 /f
