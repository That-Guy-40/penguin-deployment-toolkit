@echo off
rem 50-boot - write the boot files to the EFI system partition and the firmware boot entry.
setlocal EnableExtensions EnableDelayedExpansion
call X:\pdt\env.cmd
bcdboot W:\Windows /s S: /f UEFI || exit /b !errorlevel!
exit /b 0
