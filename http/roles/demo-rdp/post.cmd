@echo off
rem post.cmd for the demo roles (bin/smoke): report the disks and volumes the
rem installed Windows sees, so the removable media the lab attached (a USB
rem stick, an SD card) and the marker file on it can be checked from the
rem server without logging on. Runs at first logon, elevated, from
rem C:\pdt\role\; ..\id.cmd sets SRV, ID, RUN; ..\beacon.cmd sends the beacon.
rem disks.ps1 (FILES=) writes disks.txt: one "disk N|model|bus|GB|style" line per
rem disk, "vol X: ..." per volume, "marker X: <text>" where X:\PDT-MARKER.txt is.
setlocal EnableExtensions
call "%~dp0..\id.cmd"
set OUT=%~dp0..\disks.txt
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0disks.ps1" > "%OUT%" 2>&1
set DISKS=0
set MARKERS=0
for /f %%c in ('type "%OUT%" ^| find /c "disk "') do set DISKS=%%c
for /f %%c in ('type "%OUT%" ^| find /c "marker "') do set MARKERS=%%c
curl.exe -sS -T "%OUT%" "%SRV%/uploads/%ID%/%RUN%/disks.txt" -o nul --max-time 60
call "%~dp0..\beacon.cmd" role-post ok "disks=%DISKS%" "markers=%MARKERS%"
