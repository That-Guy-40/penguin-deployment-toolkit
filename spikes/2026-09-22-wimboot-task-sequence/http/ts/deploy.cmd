@echo off
setlocal EnableDelayedExpansion
set SRV=http://10.0.2.2:8090
echo [ts] spike task sequence starting (NON-DESTRUCTIVE: no diskpart writes, no setup)
wpeinit
echo [ts] --- hardware identity from the registry (no WMI needed) ---
for %%k in (SystemManufacturer SystemProductName SystemFamily SystemSKU BaseBoardProduct BIOSVersion) do (
  for /f "tokens=2,*" %%a in ('reg query HKLM\HARDWARE\DESCRIPTION\System\BIOS /v %%k 2^>nul ^| find "%%k"') do set %%k=%%b
)
echo MFR=!SystemManufacturer! PRODUCT=!SystemProductName! SKU=!SystemSKU! BOARD=!BaseBoardProduct!
echo [ts] --- WMI (wmic) ---
for /f "tokens=2 delims==" %%u in ('wmic csproduct get UUID /value ^| find "="') do set UUID=%%u
echo UUID=!UUID!
echo [ts] --- disks (read-only diskpart query) ---
echo list disk> X:\listdisk.txt
diskpart /s X:\listdisk.txt | find "Disk"
echo [ts] --- network ---
ipconfig | find "IPv4"
set /a tries=0
:wait
ping -n 1 -w 1000 10.0.2.2 >nul 2>&1 && goto netok
set /a tries+=1
if !tries! gtr 60 echo [ts] network never came up & goto nonet
ping -n 3 127.0.0.1 >nul
goto wait
:netok
echo [ts] --- beacon to server ---
cscript //nologo X:\Windows\System32\http.js "%SRV%/beacon" stage=winpe "mfr=!SystemManufacturer!" "product=!SystemProductName!" "uuid=!UUID!"
echo [ts] --- fetch per-machine config over HTTP ---
cscript //nologo X:\Windows\System32\http.js "%SRV%/ts/machine.cfg" -o X:\machine.cfg
type X:\machine.cfg
cscript //nologo X:\Windows\System32\http.js "%SRV%/beacon" stage=done
:nonet
echo [ts] spike complete. Shell left open for screenshots.
