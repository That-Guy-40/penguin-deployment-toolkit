@echo off
setlocal EnableDelayedExpansion
set SRV=http://10.0.2.2:8090
set CURL=X:\Windows\System32\curl.exe -sS
echo [ts] apply-image task sequence (spike 2) - WIPES DISK 0 OF THIS VM
wpeinit
for %%k in (SystemManufacturer SystemProductName) do (
  for /f "tokens=2,*" %%a in ('reg query HKLM\HARDWARE\DESCRIPTION\System\BIOS /v %%k 2^>nul ^| find "%%k"') do set %%k=%%b
)
:wait
ping -n 1 -w 1000 10.0.2.2 >nul 2>&1 && goto netok
ping -n 3 127.0.0.1 >nul
goto wait
:netok
%CURL% -G "%SRV%/beacon" --data-urlencode "stage=ts-start" --data-urlencode "product=!SystemProductName!"
echo [ts] 1/6 partition disk 0 (GPT: ESP 260M, MSR 16M, Windows = rest)
%CURL% -fo X:\diskpart.txt "%SRV%/ts/diskpart.txt" || goto fail
diskpart /s X:\diskpart.txt || goto fail
mkdir W:\Scratch
echo [ts] 2/6 download install.wim over HTTP to W:\
%CURL% -fo W:\install.wim "%SRV%/images/install.wim" || goto fail
%CURL% -G "%SRV%/beacon" --data-urlencode "stage=downloaded"
echo [ts] 3/6 apply image with DISM
dism /apply-image /imagefile:W:\install.wim /index:1 /applydir:W:\ /scratchdir:W:\Scratch || goto fail
del W:\install.wim
%CURL% -G "%SRV%/beacon" --data-urlencode "stage=applied"
echo [ts] 4/6 driver pack (a WIM built on Linux with wimlib) -^> dism /add-driver into the offline image
%CURL% -fo W:\drivers.wim "%SRV%/drivers/virtio-w11.wim" || goto fail
mkdir W:\Drivers
dism /apply-image /imagefile:W:\drivers.wim /index:1 /applydir:W:\Drivers /scratchdir:W:\Scratch || goto fail
dism /image:W:\ /add-driver /driver:W:\Drivers /recurse /scratchdir:W:\Scratch || goto fail
rmdir /s /q W:\Drivers
del W:\drivers.wim
%CURL% -G "%SRV%/beacon" --data-urlencode "stage=drivers-added"
echo [ts] 5/6 boot files (bcdboot) + unattend.xml into Panther
bcdboot W:\Windows /s S: /f UEFI || goto fail
mkdir W:\Windows\Panther
%CURL% -fo W:\Windows\Panther\unattend.xml "%SRV%/ts/unattend.xml" || goto fail
rmdir /s /q W:\Scratch
%CURL% -G "%SRV%/beacon" --data-urlencode "stage=ts-done"
echo [ts] 6/6 rebooting into the installed OS
wpeutil reboot
exit /b 0
:fail
set RC=!errorlevel!
%CURL% -G "%SRV%/beacon" --data-urlencode "stage=FAILED" --data-urlencode "rc=!RC!"
echo [ts] FAILED rc=!RC! - shell left open
